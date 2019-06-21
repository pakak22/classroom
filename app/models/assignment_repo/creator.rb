# frozen_string_literal: true

class AssignmentRepo
  class Creator
    DEFAULT_ERROR_MESSAGE                   = "Assignment could not be created, please try again"
    REPOSITORY_CREATION_FAILED              = "GitHub repository could not be created, please try again"
    REPOSITORY_STARTER_CODE_IMPORT_FAILED   = "We were not able to import you the starter code to your assignment, please try again." # rubocop:disable LineLength
    REPOSITORY_COLLABORATOR_ADDITION_FAILED = "We were not able to add you to the Assignment as a collaborator, please try again." # rubocop:disable LineLength
    REPOSITORY_CREATION_COMPLETE            = "Your GitHub repository was created."
    IMPORT_ONGOING                          = "Your GitHub repository is importing starter code."

    attr_reader :assignment, :user, :organization

    class Result
      class Error < StandardError
        def initialize(message, github_error_message = nil)
          message += " (#{github_error_message})" if github_error_message
          super(message)
        end
      end

      def self.success(assignment_repo)
        new(:success, assignment_repo: assignment_repo)
      end

      def self.failed(error)
        new(:failed, error: error)
      end

      def self.pending
        new(:pending)
      end

      attr_reader :error, :assignment_repo, :status

      def initialize(status, assignment_repo: nil, error: nil)
        @status          = status
        @assignment_repo = assignment_repo
        @error           = error
      end

      def success?
        @status == :success
      end

      def failed?
        @status == :failed
      end

      def pending?
        @status == :pending
      end
    end

    # Public: Create an AssignmentRepo.
    #
    # assignment - The Assignment that will own the AssignmentRepo.
    # user       - The User that the AssignmentRepo will belong to.
    #
    # Returns a AssignmentRepo::Creator::Result.
    def self.perform(assignment:, user:)
      new(assignment: assignment, user: user).perform
    end

    def initialize(assignment:, user:)
      @assignment   = assignment
      @user         = user
      @organization = assignment.organization
    end

    # rubocop:disable MethodLength
    # rubocop:disable AbcSize
    def perform
      start = Time.zone.now
      verify_organization_has_private_repos_available!

      github_repository = create_github_repository!

      assignment_repo = assignment.assignment_repos.build(
        github_repo_id: github_repository.id,
        github_global_relay_id: github_repository.node_id,
        user: user
      )

      add_user_to_repository!(assignment_repo.github_repo_id)

      if assignment.starter_code?
        push_starter_code!(assignment_repo.github_repo_id)
      end

      begin
        assignment_repo.save!
      rescue ActiveRecord::RecordInvalid => error
        raise Result::Error.new DEFAULT_ERROR_MESSAGE, error.message
      end

      duration_in_millseconds = (Time.zone.now - start) * 1_000
      GitHubClassroom.statsd.timing("exercise_repo.create.time", duration_in_millseconds)
      GitHubClassroom.statsd.increment("exercise_repo.create.success")

      Result.success(assignment_repo)
    rescue Result::Error => error
      delete_github_repository(assignment_repo.try(:github_repo_id))
      GitHubClassroom.statsd.increment("exercise_repo.create.fail")
      Result.failed(error.message)
    end
    # rubocop:enable AbcSize
    # rubocop:enable MethodLength

    # Public: Add the User to the GitHub repository
    # as a collaborator.
    #
    # Returns true if successful, otherwise raises a Result::Error
    # rubocop:disable Metrics/AbcSize
    def add_user_to_repository!(github_repository_id)
      options = {}.tap { |opt| opt[:permission] = "admin" if assignment.students_are_repo_admins? }

      github_repository = GitHubRepository.new(organization.github_client, github_repository_id)
      invitation = github_repository.invite(user.github_user.login_no_cache, options)

      user.github_user.accept_repository_invitation(invitation.id) if invitation.present?
    rescue GitHub::Error => error
      raise Result::Error.new REPOSITORY_COLLABORATOR_ADDITION_FAILED, error.message
    end
    # rubocop:enable Metrics/AbcSize

    # Public: Create the GitHub repository for the AssignmentRepo.
    #
    # Returns an Integer ID or raises a Result::Error
    def create_github_repository!
      repository_name = generate_github_repository_name

      options = {
        private: assignment.private?,
        description: "#{repository_name} created by GitHub Classroom"
      }

      organization.github_organization.create_repository("", options)
    rescue GitHub::Error => error
      raise Result::Error.new REPOSITORY_CREATION_FAILED, error.message
    end

    def delete_github_repository(github_repo_id)
      return true if github_repo_id.nil?
      organization.github_organization.delete_repository(github_repo_id)
    rescue GitHub::Error
      true
    end

    # Public: Push starter code to the newly created GitHub
    # repository.
    #
    # github_repo_id - The Integer id of the GitHub repository.
    #
    # Returns true of raises a Result::Error.
    def push_starter_code!(github_repo_id)
      client = assignment.creator.github_client
      starter_code_repo_id = assignment.starter_code_repo_id

      assignment_repository   = GitHubRepository.new(client, github_repo_id)
      starter_code_repository = GitHubRepository.new(client, starter_code_repo_id)

      assignment_repository.get_starter_code_from(starter_code_repository)
    rescue GitHub::Error => error
      raise Result::Error.new REPOSITORY_STARTER_CODE_IMPORT_FAILED, error.message
    end

    # Public: Ensure that we can make a private repository on GitHub.
    #
    # Returns True or raises a Result::Error with a helpful message.
    # rubocop:disable Metrics/AbcSize
    # rubocop:disable MethodLength
    def verify_organization_has_private_repos_available!
      return true if assignment.public?

      begin
        github_organization_plan = GitHubOrganization.new(organization.github_client, organization.github_id).plan
      rescue GitHub::Error => error
        raise Result::Error, error.message
      end

      owned_private_repos = github_organization_plan[:owned_private_repos]
      private_repos       = github_organization_plan[:private_repos]

      return true if owned_private_repos < private_repos

      error_message = <<~ERROR
        Cannot make this private assignment, your limit of #{private_repos}
        #{'repository'.pluralize(private_repos)} has been reached. You can request
        a larger plan for free at https://education.github.com/discount
      ERROR

      raise Result::Error, error_message
    end
    # rubocop:enable Metrics/AbcSize
    # rubocop:enable MethodLength

    private

    #####################################
    # GitHub repository name generation #
    #####################################

    # rubocop:disable AbcSize
    def generate_github_repository_name
      suffix_count = 0

      owner           = organization.github_organization.login_no_cache
      repository_name = "#{assignment.slug}-#{user.github_user.login_no_cache}"

      loop do
        name = "#{owner}/#{suffixed_repo_name(repository_name, suffix_count)}"
        break unless GitHubRepository.present?(organization.github_client, name)

        suffix_count += 1
      end

      suffixed_repo_name(repository_name, suffix_count)
    end
    # rubocop:enable AbcSize

    def suffixed_repo_name(repository_name, suffix_count)
      return repository_name if suffix_count.zero?

      suffix = "-#{suffix_count}"
      repository_name.truncate(100 - suffix.length, omission: "") + suffix
    end
  end
end
