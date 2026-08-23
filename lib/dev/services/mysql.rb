require 'dev'
require 'fileutils'
require 'open3'
require 'socket'
require 'time'

module Dev
  module Services
    class MySQL
      REQUIRED_BINARIES = %w(mariadbd mariadb mariadb-admin mariadb-install-db).freeze
      HOST = '127.0.0.1'
      READINESS_TIMEOUT = 30
      READINESS_INTERVAL = 0.25

      Record = Struct.new(:key, :name, :pid, :command, :log_path, :pid_path, keyword_init: true)

      def self.required_binaries
        REQUIRED_BINARIES
      end

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

      def prepare
        progress("checking MariaDB service #{@name}")
        require_password!
        require_binaries!
        progress("allocating MariaDB paths and port for #{@name}")
        persist_allocations_and_record
        progress("writing MariaDB config for #{@name}")
        write_config
        if datadir_initialized?
          progress("reusing MariaDB datadir for #{@name}")
        else
          progress("initializing MariaDB datadir for #{@name}")
          initialize_datadir
        end
        persist_record('state' => 'stopped', 'ready' => false, 'datadir_initialized' => true)
      end

      def start
        prepare
        refresh
        current = service_record
        if current && current['pid'] && running?(current['pid']) && healthcheck
          persist_record('state' => 'running', 'ready' => true)
          return record_from_service(service_record)
        end

        remove_stale_runtime_files
        progress("starting MariaDB daemon for #{@name}")
        log = File.open(paths.fetch('log_path'), 'a')
        pid = Process.spawn(
          daemon_env,
          binary('mariadbd'), "--defaults-file=#{paths.fetch('config_path')}",
          chdir: @instance.state_root,
          pgroup: true,
          out: log,
          err: log
        )
        Process.detach(pid)
        log.close
        File.write(paths.fetch('pid_path'), "#{pid}\n")
        persist_record('pid' => pid, 'state' => 'starting', 'ready' => false, 'started_at' => timestamp)

        progress("waiting for MariaDB #{@name} readiness")
        wait_until_ready(pid)
        progress("creating MariaDB databases and user for #{@name}")
        create_databases_and_user
        persist_record('state' => 'running', 'ready' => true)
        progress("MariaDB service #{@name} is ready")
        record_from_service(service_record)
      rescue
        log&.close unless log&.closed?
        persist_record('state' => 'failed', 'ready' => false) if service_record
        raise
      end

      def refresh
        record = service_record
        return unless record && record['pid']
        return if running?(record['pid'])

        FileUtils.rm_f(record['pid_path']) if record['pid_path']
        progress("clearing stale MariaDB pid for #{@name}")
        persist_record_without_runtime(record, 'stale')
      end

      def healthcheck
        system(client_env, binary('mariadb-admin'), '--protocol=socket', "--socket=#{paths.fetch('socket_path')}", '-uroot', 'ping', out: File::NULL, err: File::NULL)
      end

      def stop
        refresh
        record = service_record
        return nil unless record && record['pid']

        pid = Integer(record['pid'])
        system(client_env, binary('mariadb-admin'), '--protocol=socket', "--socket=#{paths.fetch('socket_path')}", '-uroot', 'shutdown', out: File::NULL, err: File::NULL)
        40.times do
          break unless running?(pid)
          sleep 0.25
        end
        stop_process_group(pid) if running?(pid)

        FileUtils.rm_f(paths.fetch('pid_path'))
        stopped = record_from_service(record)
        persist_record_without_runtime(record, 'stopped')
        stopped
      end

      def reset
        stop
        record = service_record
        allocation = @state.ensure!.fetch('allocations', {}).fetch('ports', {})[@name]
        return nil unless record || allocation

        reset_paths = paths_to_reset(record)
        reset_paths.each { |path| assert_owned_path!(path) }
        reset_paths.each { |path| FileUtils.rm_rf(path) }

        @state.mutate do |data|
          data['services'].delete(@name)
          data.fetch('allocations', {}).fetch('sockets', {}).delete(@name)
        end

        record_from_service((record || base_record(nil)).merge('pid' => nil))
      end

      def resolved_env(include_password: false)
        env = {
          'MYSQL_HOST' => HOST,
          'MYSQL_PORT' => port.to_s,
          'MYSQL_SOCKET' => paths.fetch('socket_path'),
          'MYSQL_DATABASE' => database,
          'MYSQL_TEST_DATABASE' => test_database,
          'MYSQL_USERNAME' => username,
          'DATABASE_URL' => database_url(database),
          'TEST_DATABASE_URL' => database_url(test_database),
        }
        env['MYSQL_PASSWORD'] = password if include_password && password_env && password
        env.reject { |_key, value| value.nil? || value.to_s.empty? }
      end

      def paths
        @paths ||= {
          'data_dir' => File.join(@instance.state_root, 'data', @name),
          'log_path' => File.join(@instance.state_root, 'logs', "#{@name}.log"),
          'pid_path' => File.join(@instance.state_root, 'pids', "#{@name}.pid"),
          'socket_path' => socket_path,
          'config_path' => File.join(@instance.state_root, 'run', @name, 'my.cnf'),
          'run_dir' => File.join(@instance.state_root, 'run', @name),
          'tmp_dir' => File.join(@instance.state_root, 'tmp', @name),
        }
      end

      def generated_config
        <<~CNF
          [mysqld]
          datadir=#{paths.fetch('data_dir')}
          socket=#{paths.fetch('socket_path')}
          port=#{port}
          bind-address=#{HOST}
          pid-file=#{paths.fetch('pid_path')}
          log-error=#{paths.fetch('log_path')}
          tmpdir=#{paths.fetch('tmp_dir')}
          skip-networking=0
        CNF
      end

      private

      def persist_allocations_and_record
        @state.mutate do |data|
          data['allocations']['ports'][@name] = port_allocation(data)
          data['allocations']['sockets'][@name] = paths.fetch('socket_path')
          data['services'][@name] = base_record(data['services'][@name])
        end
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

      def write_config
        FileUtils.mkdir_p(paths.fetch('run_dir'))
        FileUtils.mkdir_p(File.dirname(paths.fetch('log_path')))
        FileUtils.mkdir_p(File.dirname(paths.fetch('pid_path')))
        FileUtils.mkdir_p(File.dirname(paths.fetch('socket_path')))
        FileUtils.mkdir_p(paths.fetch('tmp_dir'))
        File.write(paths.fetch('config_path'), generated_config)
      end

      def initialize_datadir
        if Dir.exist?(paths.fetch('data_dir')) && !Dir.empty?(paths.fetch('data_dir'))
          raise(Abort, "services.#{@name} datadir exists but is not initialized: #{paths.fetch('data_dir')}") unless datadir_looks_initialized?
          return
        end

        FileUtils.mkdir_p(paths.fetch('data_dir'))
        ok = system(
          client_env,
          binary('mariadb-install-db'),
          "--datadir=#{paths.fetch('data_dir')}",
          '--auth-root-authentication-method=normal',
          out: paths.fetch('log_path'),
          err: [:child, :out]
        )
        raise(Abort, "services.#{@name} failed to initialize MariaDB datadir; see #{paths.fetch('log_path')}") unless ok
      end

      def datadir_initialized?
        service_record&.fetch('datadir_initialized', false) && datadir_looks_initialized?
      end

      def datadir_looks_initialized?
        File.directory?(File.join(paths.fetch('data_dir'), 'mysql')) || File.file?(File.join(paths.fetch('data_dir'), 'ibdata1'))
      end

      def wait_until_ready(pid)
        deadline = Time.now + READINESS_TIMEOUT
        until Time.now > deadline
          raise(Abort, "services.#{@name} MariaDB process exited before readiness; see #{paths.fetch('log_path')}") unless running?(pid)
          return true if File.exist?(paths.fetch('socket_path')) && healthcheck
          sleep READINESS_INTERVAL
        end

        raise(Abort, "services.#{@name} did not become ready within #{READINESS_TIMEOUT}s; see #{paths.fetch('log_path')}")
      end

      def create_databases_and_user
        statements = []
        [database, test_database].compact.each do |db|
          statements << "CREATE DATABASE IF NOT EXISTS #{identifier(db)}"
        end
        %w(localhost 127.0.0.1).each do |host|
          statements << "CREATE USER IF NOT EXISTS #{literal(username)}@#{literal(host)} IDENTIFIED BY #{literal(password.to_s)}"
          [database, test_database].compact.each do |db|
            statements << "GRANT ALL PRIVILEGES ON #{identifier(db)}.* TO #{literal(username)}@#{literal(host)}"
          end
        end
        statements << 'FLUSH PRIVILEGES'
        run_sql(statements.join('; ') + ';')
      end

      def run_sql(sql)
        ok = system(client_env, binary('mariadb'), '--protocol=socket', "--socket=#{paths.fetch('socket_path')}", '-uroot', '-e', sql, out: File::NULL, err: paths.fetch('log_path'))
        raise(Abort, "services.#{@name} failed to create databases or grants; see #{paths.fetch('log_path')}") unless ok
      end

      def identifier(value)
        "`#{value.to_s.gsub('`', '``')}`"
      end

      def literal(value)
        "'#{value.to_s.gsub('\\', '\\\\').gsub("'", "''")}'"
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

      def base_record(existing)
        now = timestamp
        (existing || {}).merge(
          'name' => @name,
          'type' => 'mysql',
          'state' => existing&.fetch('state', 'stopped') || 'stopped',
          'pid_path' => paths.fetch('pid_path'),
          'log_path' => paths.fetch('log_path'),
          'data_dir' => paths.fetch('data_dir'),
          'socket_path' => paths.fetch('socket_path'),
          'config_path' => paths.fetch('config_path'),
          'ports' => { @name => port },
          'datadir_initialized' => datadir_looks_initialized?,
          'ready' => existing&.fetch('ready', false) || false,
          'resolved_env' => resolved_env,
          'created_at' => existing&.fetch('created_at', now) || now,
          'updated_at' => now
        )
      end

      def service_record
        @state.ensure!.fetch('services', {})[@name]
      end

      def paths_to_reset(record)
        if record
          %w(data_dir pid_path socket_path config_path run_dir tmp_dir).map do |key|
            raise(Abort, "Cannot safely reset #{@name}: state is missing #{key}.") if key == 'data_dir' && !record.key?(key)

            value = record[key] || paths[key]
            raise(Abort, "Cannot safely reset #{@name}: state is missing #{key}.") if key == 'data_dir' && value.to_s.empty?

            value
          end.compact
        else
          %w(data_dir pid_path socket_path config_path run_dir tmp_dir).map { |key| paths[key] }
        end
      end

      def assert_owned_path!(path)
        expanded = File.expand_path(path)
        root = File.expand_path(@instance.state_root)
        return if expanded == root || expanded.start_with?(root + File::SEPARATOR)
        return if expanded.start_with?(File.expand_path(socket_root) + File::SEPARATOR)

        raise(Abort, "Cannot safely reset #{@name}: path is outside minidev-owned paths: #{path}")
      end

      def socket_path
        File.join(socket_root, short_instance_id, "#{safe_service_name}.sock")
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

      def record_from_service(service)
        return nil unless service
        Record.new(
          key: @name,
          name: @name,
          pid: service['pid'] && Integer(service['pid']),
          command: 'mariadbd',
          log_path: service['log_path'],
          pid_path: service['pid_path']
        )
      end

      def port
        return @resolved_port if @resolved_port

        # `port` is also used while mutating instance state. Reuse the in-memory
        # state snapshot in that path so we do not try to reacquire the same lock.
        data = @state.data || @state.ensure!
        allocation = data.fetch('allocations', {}).fetch('ports', {})[@name]
        allocation && allocation['port']
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

      def project_slug
        slug = File.basename(@project.dir).downcase.gsub(/[^a-z0-9_]+/, '_').gsub(/_+/, '_').gsub(/\A_|_\z/, '')
        slug.empty? || slug =~ /\A[0-9]/ ? "project_#{slug}" : slug
      end

      def database_url(db)
        user = username ? "#{username}@" : ''
        "mysql2://#{user}#{HOST}:#{port}/#{db}" if db && port
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
        missing = REQUIRED_BINARIES.reject { |name| binary_path(name) }
        return if missing.empty?

        raise(Abort, "services.#{@name} requires MariaDB binaries missing from PATH: #{missing.join(', ')}. Enter the Nix-backed environment or add MariaDB to the project Nix expression.")
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

      def remove_stale_runtime_files
        FileUtils.rm_f(paths.fetch('pid_path'))
        FileUtils.rm_f(paths.fetch('socket_path'))
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
