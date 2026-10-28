require 'dev'
require 'socket'
require 'time'

module Dev
  module Services
    class ManagedServer
      HOST = '127.0.0.1'

      def initialize(project, name, config, instance: Instance.for_project(project), state: InstanceState.new(instance), env: ENV.to_h, reporter: nil)
        @project = project
        @name = name.to_s
        @config = config.to_h
        @instance = instance
        @state = state
        @env = env
        @reporter = reporter
      end

      attr_reader :name

      private

      def persist_allocations_and_record
        @state.mutate do |data|
          data['allocations']['ports'][@name] = port_allocation(data)
          data['allocations']['sockets'][@name] = socket_allocation_path
          data['services'][@name] = base_record(data['services'][@name])
        end
      end

      # The allocation records one socket location per service. MariaDB owns a
      # socket file; PostgreSQL owns the directory it creates its socket in.
      def socket_allocation_path
        paths.fetch('socket_path')
      end

      def port_allocation(data)
        existing = data.fetch('allocations', {}).fetch('ports', {})[@name]
        existing_port = existing && existing['port']
        selected = if existing_port && reusable_port?(Integer(existing_port), data.fetch('services', {})[@name])
          Integer(existing_port)
        else
          allocate_port
        end

        @resolved_port = selected
        {
          'name' => @name,
          'port' => selected,
          'protocol' => 'tcp',
          'host' => HOST,
          'allocated_at' => existing && Integer(existing['port']) == selected ? existing['allocated_at'] : timestamp,
        }
      end

      def reusable_port?(candidate, record)
        return true if port_free?(candidate)
        record && record['pid'] && running?(record['pid'])
      end

      def allocate_port
        server = TCPServer.new(HOST, 0)
        server.addr[1]
      ensure
        server&.close
      end

      def port_free?(candidate)
        server = TCPServer.new(HOST, candidate)
        true
      rescue Errno::EADDRINUSE, Errno::EACCES
        false
      ensure
        server&.close
      end

      def port
        return @resolved_port if @resolved_port

        # `port` is also used while mutating instance state. Reuse the in-memory
        # state snapshot in that path so we do not try to reacquire the same lock.
        data = @state.data || @state.ensure!
        allocation = data.fetch('allocations', {}).fetch('ports', {})[@name]
        allocation && allocation['port']
      end

      def persist_record(attrs)
        @state.mutate do |data|
          data['services'][@name] = base_record(data['services'][@name]).merge(attrs).merge('updated_at' => timestamp)
        end
      end

      def persist_record_without_runtime(record, state)
        @state.mutate do |data|
          service = base_record(data['services'][@name]).merge(record).merge(
            'state' => state,
            'ready' => false,
            'updated_at' => timestamp
          )
          service.delete('pid')
          data['services'][@name] = service
        end
      end

      def service_record
        @state.ensure!.fetch('services', {})[@name]
      end

      def assert_owned_path!(path)
        expanded = File.expand_path(path)
        root = File.expand_path(@instance.state_root)
        return if expanded == root || expanded.start_with?(root + File::SEPARATOR)
        return if expanded.start_with?(File.expand_path(socket_root) + File::SEPARATOR)

        raise(Abort, "Cannot safely reset #{@name}: path is outside minidev-owned paths: #{path}")
      end

      def socket_root
        '/tmp/minidev'
      end

      def short_instance_id
        @instance.instance_id.gsub(/[^a-zA-Z0-9_-]/, '-')[0, 15]
      end

      def safe_service_name
        @name.gsub(/[^a-zA-Z0-9_-]/, '-')
      end

      def project_slug
        slug = File.basename(@project.dir).downcase.gsub(/[^a-z0-9_]+/, '_').gsub(/_+/, '_').gsub(/\A_|_\z/, '')
        slug.empty? || slug =~ /\A[0-9]/ ? "project_#{slug}" : slug
      end

      def database
        @config['database'] || "#{project_slug}_development"
      end

      def test_database
        @config['test_database'] || "#{project_slug}_test"
      end

      def username
        @config['username'] || project_slug
      end

      def password_env
        @config['password_env']
      end

      def password
        @env[password_env] if password_env
      end

      def require_password!
        return unless password_env
        return if @env.key?(password_env)

        raise(Abort, "services.#{@name}.password_env is set to #{password_env}, but that environment variable is not set")
      end

      def require_binaries!
        missing = self.class.required_binaries.reject { |name| binary_path(name) }
        return if missing.empty?

        raise(Abort, "services.#{@name} requires #{binary_engine_name} binaries missing from PATH: #{missing.join(', ')}. Enter the Nix-backed environment or add #{binary_engine_name} to the project Nix expression.")
      end

      def binary(name)
        binary_path(name) || name
      end

      def binary_path(name)
        @binaries ||= {}
        return @binaries[name] if @binaries.key?(name)

        @binaries[name] = @env.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |path| File.file?(path) && File.executable?(path) }
      end

      def daemon_env
        stringify_hash(@env).merge(stringify_hash(@config.fetch('env', {})))
      end

      def client_env
        stringify_hash(@env)
      end

      def stringify_hash(hash)
        hash.to_h.each_with_object({}) { |(key, value), out| out[key.to_s] = value.to_s }
      end

      def running?(pid)
        Process.kill(0, Integer(pid))
        true
      rescue Errno::ESRCH, ArgumentError, TypeError
        false
      end

      def stop_process_group(pid)
        Process.kill('TERM', -pid)
        10.times do
          return unless running?(pid)
          sleep 0.1
        end
        Process.kill('KILL', -pid) if running?(pid)
      rescue Errno::ESRCH
        nil
      end

      def timestamp
        Time.now.utc.iso8601
      end

      def progress(message)
        @reporter&.call(message)
      end
    end
  end
end
