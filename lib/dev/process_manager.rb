require 'dev'
require 'digest'
require 'fileutils'
require 'time'
require 'yaml'

module Dev
  class ProcessManager
    Record = Struct.new(:key, :name, :pid, :command, :log_path, :pid_path, keyword_init: true)
    COMMAND_HASH_LENGTH = 12

    def self.raw_command_name(sh, args = [], occurrence = nil)
      name = "command.#{Digest::SHA256.hexdigest(command_string(sh, args))[0, COMMAND_HASH_LENGTH]}"
      occurrence.nil? ? name : "#{name}.#{occurrence}"
    end

    def self.command_string(sh, args)
      ([sh] + args).join(' ')
    end

    def initialize(project, instance: Instance.for_project(project), state: InstanceState.new(instance))
      @project = project
      @instance = instance
      @state = state
    end

    def ps
      alive = []
      @state.mutate do |data|
        process_services(data).each do |key, service|
          pid = service['pid']
          next unless pid

          if running?(pid)
            alive << record_from_service(key, service)
          else
            clear_liveness(service, 'stale')
          end
        end
      end
      alive + legacy_live_records
    end

    def start(name, sh, args, env: nil)
      records = ps
      key = service_key(name)
      existing = records.find { |record| record.key == key || record.name == name }
      raise(Abort, "#{name} is already running with PID #{existing.pid}") if existing

      FileUtils.mkdir_p(@instance.paths['logs_dir'])
      FileUtils.mkdir_p(@instance.paths['pids_dir'])

      log_path = File.join(@instance.paths['logs_dir'], "#{key}.log")
      pid_path = File.join(@instance.paths['pids_dir'], "#{key}.pid")
      log = File.open(log_path, 'a')
      pid = Process.spawn(
        env || default_env,
        Shell.bash, '-c', wrap_shell(sh), '--', *args,
        chdir: @project.dir,
        pgroup: true,
        out: log,
        err: log
      )
      Process.detach(pid)
      log.close
      File.write(pid_path, "#{pid}\n")

      command = self.class.command_string(sh, args)
      now = timestamp
      @state.mutate do |data|
        data['services'][key] = {
          'name' => key,
          'display_name' => name,
          'type' => 'process',
          'state' => 'running',
          'pid' => pid,
          'command' => command,
          'pid_path' => pid_path,
          'log_path' => log_path,
          'ready' => nil,
          'source' => 'process_manager',
          'started_at' => now,
          'updated_at' => now,
        }
      end

      Record.new(key: key, name: name, pid: pid, command: command, log_path: log_path, pid_path: pid_path)
    rescue
      log&.close unless log&.closed?
      FileUtils.rm_f(pid_path) if pid_path
      raise
    end

    def stop(names = nil)
      records = ps
      names = Array(names).map(&:to_s)
      targets = names.empty? ? records : records.select { |record| names.include?(record.name) || names.include?(record.key) }

      if names.any?
        known = targets.flat_map { |record| [record.name, record.key] }
        missing = names - known
        raise(Abort, "Unknown process #{missing.join(', ')}") unless missing.empty?
      end

      targets.each { |record| stop_record(record) }
      stopped_keys = targets.map(&:key)
      @state.mutate do |data|
        process_services(data).each do |key, service|
          clear_liveness(service, 'stopped') if stopped_keys.include?(key)
        end
      end
      targets
    end

    def cleanup!
      @state.ensure!
    end

    def state_dir
      File.join(@project.dir, '.dev')
    end

    def registry_path
      File.join(state_dir, 'pid.tmp')
    end

    private

    def service_key(name)
      suffix = ".#{@instance.environment}.#{@instance.slugged_worktree_name}"
      name.end_with?(suffix) ? name : "#{name}#{suffix}"
    end

    def process_services(data)
      data.fetch('services', {}).select { |_key, service| service['type'] == 'process' }
    end

    def record_from_service(key, service)
      Record.new(
        key: key,
        name: service['display_name'] || service['name'] || key,
        pid: Integer(service['pid']),
        command: service['command'],
        log_path: service['log_path'],
        pid_path: service['pid_path']
      )
    end

    def clear_liveness(service, state)
      FileUtils.rm_f(service['pid_path']) if service['pid_path']
      service.delete('pid')
      service['state'] = state
      service['ready'] = nil
      service['updated_at'] = timestamp
    end

    def load_records
      return [] unless File.exist?(registry_path)

      YAML.load_file(registry_path).to_a.map do |row|
        Record.new(
          key: row.fetch('name'),
          name: row.fetch('name'),
          pid: Integer(row.fetch('pid')),
          command: row.fetch('command'),
          log_path: row['log_path']
        )
      end
    end

    def legacy_live_records
      load_records.select { |record| running?(record.pid) }
    end

    def running?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def stop_record(record)
      begin
        Process.kill('TERM', -record.pid)
      rescue Errno::ESRCH
        return
      end

      10.times do
        return unless running?(record.pid)
        sleep(0.1)
      end

      Process.kill('KILL', -record.pid)
    rescue Errno::ESRCH
      nil
    end

    def timestamp
      Time.now.utc.iso8601
    end

    def wrap_shell(sh)
      sh = sh.dup
      sh.concat(' "$@"') if sh.lines.size == 1 && sh !~ /\$[@\*]/
      %Q{runcmd() {\n#{sh}\n}\nruncmd "$@"}
    end

    def default_env
      Services::EnvBuilder.new(@project, instance: @instance, state: @state).command_env
    end
  end
end
