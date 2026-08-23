require 'dev'
require 'fileutils'
require 'json'
require 'time'

module Dev
  class InstanceState
    SCHEMA = 1

    attr_reader :instance, :data

    def initialize(instance)
      @instance = instance
    end

    def ensure!
      with_lock do
        @data = File.exist?(state_path) ? load_state : initial_state
        write_state(@data) unless File.exist?(state_path)
      end
      write_pointer
      @data
    end

    def mutate
      with_lock do
        @data = File.exist?(state_path) ? load_state : initial_state
        yield @data
        @data['updated_at'] = timestamp
        write_state(@data)
      end
      write_pointer
      @data
    end

    def state_path
      File.join(instance.state_root, 'instance.json')
    end

    def lock_path
      File.join(instance.state_root, 'lock')
    end

    def pointer_path
      File.join(instance.project_root, '.dev', 'instance.json')
    end

    private

    def with_lock
      FileUtils.mkdir_p(instance.state_root)
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def load_state
      state = JSON.parse(File.read(state_path))
      validate_state(state)
      state
    rescue JSON::ParserError => e
      raise(Abort, "Invalid instance state JSON: #{e.message}")
    end

    def validate_state(state)
      schema = state['schema']
      raise(Abort, 'Invalid instance state: missing schema') unless schema
      raise(Abort, "Unsupported instance state schema #{schema}") if Integer(schema) > SCHEMA

      identity = state['identity'] || {}
      return if identity['instance_id'] == instance.instance_id

      raise(Abort, 'Instance state identity does not match derived instance')
    end

    def initial_state
      now = timestamp
      {
        'schema' => SCHEMA,
        'identity' => instance.state_identity,
        'paths' => instance.paths,
        'allocations' => {
          'ports' => {},
          'sockets' => {},
        },
        'services' => {},
        'resolved_env' => instance.metadata_env,
        'created_at' => now,
        'updated_at' => now,
      }
    end

    def write_state(state)
      FileUtils.mkdir_p(instance.paths['logs_dir'])
      FileUtils.mkdir_p(instance.paths['pids_dir'])
      FileUtils.mkdir_p(instance.paths['sockets_dir'])
      FileUtils.mkdir_p(instance.paths['data_dir'])
      FileUtils.mkdir_p(instance.paths['run_dir'])
      FileUtils.mkdir_p(instance.paths['tmp_dir'])

      tmp_path = "#{state_path}.#{$$}.tmp"
      File.write(tmp_path, JSON.pretty_generate(state) + "\n")
      File.rename(tmp_path, state_path)
    ensure
      FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
    end

    def write_pointer
      FileUtils.mkdir_p(File.dirname(pointer_path))
      pointer = {
        'schema' => SCHEMA,
        'instance_id' => instance.instance_id,
        'state_root' => instance.state_root,
        'project_root' => instance.project_root,
        'worktree_root' => instance.worktree_root,
        'environment' => instance.environment,
        'written_at' => timestamp,
      }
      tmp_path = "#{pointer_path}.#{$$}.tmp"
      File.write(tmp_path, JSON.pretty_generate(pointer) + "\n")
      File.rename(tmp_path, pointer_path)
    ensure
      FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
    end

    def timestamp
      Time.now.utc.iso8601
    end
  end
end
