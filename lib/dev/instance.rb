require 'dev'
require 'digest'
require 'json'
require 'open3'

module Dev
  class Instance
    IDENTITY_SCHEMA = 1
    ENVIRONMENT = 'development'

    attr_reader :project_root, :worktree_root, :environment, :instance_id, :label, :state_root

    def self.for_project(project)
      new(project_root: project.dir)
    end

    def initialize(project_root:, worktree_root: nil, environment: ENVIRONMENT)
      @project_root = canonical_path(project_root)
      @worktree_root = canonical_path(worktree_root || resolve_worktree_root(@project_root))
      @environment = environment
      @instance_id = derive_instance_id
      @label = "#{File.basename(@project_root)}:#{@environment}"
      @state_root = File.join(global_state_root, 'instances', @instance_id)
    end

    def identity
      {
        'schema' => IDENTITY_SCHEMA,
        'instance_id' => instance_id,
        'label' => label,
        'project_root' => project_root,
        'worktree_root' => worktree_root,
        'environment' => environment,
        'state_root' => state_root,
      }
    end

    def state_identity
      identity.reject { |key, _| key == 'schema' || key == 'state_root' }
    end

    def metadata_env
      {
        'MINIDEV_INSTANCE_ID' => instance_id,
        'MINIDEV_STATE_ROOT' => state_root,
        'MINIDEV_PROJECT_ROOT' => project_root,
        'MINIDEV_WORKTREE_ROOT' => worktree_root,
        'MINIDEV_ENVIRONMENT' => environment,
      }
    end

    def slugged_worktree_name
      File.basename(worktree_root)
        .downcase
        .gsub(/[^a-z0-9]+/, '-')
        .gsub(/-+/, '-')
        .gsub(/\A-|\-\z/, '')
    end

    def paths
      {
        'state_root' => state_root,
        'logs_dir' => File.join(state_root, 'logs'),
        'pids_dir' => File.join(state_root, 'pids'),
        'sockets_dir' => File.join(state_root, 'sockets'),
        'data_dir' => File.join(state_root, 'data'),
        'run_dir' => File.join(state_root, 'run'),
        'tmp_dir' => File.join(state_root, 'tmp'),
      }
    end

    private

    def derive_instance_id
      payload = {
        'environment' => environment,
        'project_root' => project_root,
        'schema' => IDENTITY_SCHEMA,
        'worktree_root' => worktree_root,
      }

      "v1-#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    def global_state_root
      File.join(Dir.home, '.local', 'state', 'minidev')
    end

    def canonical_path(path)
      File.realpath(File.expand_path(path))
    end

    def resolve_worktree_root(project_root)
      output, status = Open3.capture2e('git', '-C', project_root, 'rev-parse', '--show-toplevel')
      return output.strip if status.success? && !output.strip.empty?

      project_root
    end
  end
end
