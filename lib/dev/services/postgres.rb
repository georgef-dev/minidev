require 'dev'
require 'fileutils'
require 'open3'
require 'time'

module Dev
  module Services
    class Postgres < ManagedServer
      REQUIRED_BINARIES = %w(postgres initdb psql pg_isready pg_ctl).freeze
      READINESS_TIMEOUT = 30
      READINESS_INTERVAL = 0.25
      SOCKET_PATH_LIMIT = 103
      # PostgreSQL appends this basename to `unix_socket_directories` itself to form
      # the real bind path. Use the widest possible port (5 digits) so the limit
      # check is deterministic rather than only failing for some port numbers.
      SOCKET_BASENAME_MAX = '.s.PGSQL.65535'
      SOCKET_SUFFIX_MAX_BYTES = (File::SEPARATOR + SOCKET_BASENAME_MAX).bytesize

      Record = Struct.new(:key, :name, :pid, :command, :log_path, :pid_path, keyword_init: true)

      def self.required_binaries
        REQUIRED_BINARIES
      end

      def prepare
        progress("checking PostgreSQL service #{@name}")
        require_socket_dir_within_limit!
        require_password!
        require_binaries!
        progress("allocating PostgreSQL paths and port for #{@name}")
        persist_allocations_and_record
        progress("writing PostgreSQL config for #{@name}")
        write_config
        if datadir_initialized?
          progress("reusing PostgreSQL datadir for #{@name}")
        else
          progress("initializing PostgreSQL datadir for #{@name}")
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
        progress("starting PostgreSQL daemon for #{@name}")
        log = File.open(paths.fetch('log_path'), 'a')
        pid = Process.spawn(
          daemon_env,
          binary('postgres'), "--config-file=#{paths.fetch('config_path')}",
          chdir: @instance.state_root,
          pgroup: true,
          out: log,
          err: log
        )
        Process.detach(pid)
        log.close
        File.write(paths.fetch('pid_path'), "#{pid}\n")
        persist_record('pid' => pid, 'state' => 'starting', 'ready' => false, 'started_at' => timestamp)

        progress("waiting for PostgreSQL #{@name} readiness")
        wait_until_ready(pid)
        progress("creating PostgreSQL databases and role for #{@name}")
        create_databases_and_user
        persist_record('state' => 'running', 'ready' => true)
        progress("PostgreSQL service #{@name} is ready")
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
        progress("clearing stale PostgreSQL pid for #{@name}")
        persist_record_without_runtime(record, 'stale')
      end

      def healthcheck
        system(client_env, binary('pg_isready'), "--host=#{paths.fetch('socket_dir')}", "--port=#{port}", '--username=postgres', '--quiet', out: File::NULL, err: File::NULL)
      end

      def stop
        refresh
        record = service_record
        return nil unless record && record['pid']

        pid = Integer(record['pid'])
        system(client_env, binary('pg_ctl'), "--pgdata=#{paths.fetch('data_dir')}", 'stop', '--mode=fast', '--silent', out: File::NULL, err: File::NULL)
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
          'POSTGRES_HOST' => HOST,
          'POSTGRES_PORT' => port.to_s,
          'POSTGRES_SOCKET_DIR' => paths.fetch('socket_dir'),
          'POSTGRES_DATABASE' => database,
          'POSTGRES_TEST_DATABASE' => test_database,
          'POSTGRES_USERNAME' => username,
          'DATABASE_URL' => database_url(database),
          'TEST_DATABASE_URL' => database_url(test_database),
        }
        env['POSTGRES_PASSWORD'] = password if include_password && password_env && password
        env.reject { |_key, value| value.nil? || value.to_s.empty? }
      end

      def paths
        @paths ||= {
          'data_dir' => File.join(@instance.state_root, 'data', @name),
          'log_path' => File.join(@instance.state_root, 'logs', "#{@name}.log"),
          'pid_path' => File.join(@instance.state_root, 'pids', "#{@name}.pid"),
          'socket_dir' => socket_dir,
          'config_path' => File.join(@instance.state_root, 'run', @name, 'postgresql.conf'),
          'run_dir' => File.join(@instance.state_root, 'run', @name),
          'tmp_dir' => File.join(@instance.state_root, 'tmp', @name),
        }
      end

      def generated_config
        <<~CONF
          data_directory = '#{paths.fetch('data_dir')}'
          unix_socket_directories = '#{paths.fetch('socket_dir')}'
          port = #{port}
          listen_addresses = '127.0.0.1'
          log_destination = 'stderr'
          logging_collector = off
        CONF
      end

      private

      def require_socket_dir_within_limit!
        socket_dir_budget = SOCKET_PATH_LIMIT - SOCKET_SUFFIX_MAX_BYTES
        return if paths.fetch('socket_dir').bytesize <= socket_dir_budget

        raise(Abort, "services.#{@name} socket path would exceed the #{SOCKET_PATH_LIMIT}-byte Unix socket limit once PostgreSQL appends its socket file name; use a shorter service name.")
      end

      def write_config
        FileUtils.mkdir_p(paths.fetch('run_dir'))
        FileUtils.mkdir_p(File.dirname(paths.fetch('log_path')))
        FileUtils.mkdir_p(File.dirname(paths.fetch('pid_path')))
        FileUtils.mkdir_p(paths.fetch('socket_dir'))
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
          binary('initdb'),
          "--pgdata=#{paths.fetch('data_dir')}",
          '--username=postgres',
          '--auth=trust',
          '--encoding=UTF8',
          out: paths.fetch('log_path'),
          err: [:child, :out]
        )
        raise(Abort, "services.#{@name} failed to initialize PostgreSQL datadir; see #{paths.fetch('log_path')}") unless ok
      end

      def datadir_initialized?
        service_record&.fetch('datadir_initialized', false) && datadir_looks_initialized?
      end

      def datadir_looks_initialized?
        File.file?(File.join(paths.fetch('data_dir'), 'PG_VERSION'))
      end

      def wait_until_ready(pid)
        deadline = Time.now + READINESS_TIMEOUT
        until Time.now > deadline
          raise(Abort, "services.#{@name} PostgreSQL process exited before readiness; see #{paths.fetch('log_path')}") unless running?(pid)
          return true if healthcheck
          sleep READINESS_INTERVAL
        end

        raise(Abort, "services.#{@name} did not become ready within #{READINESS_TIMEOUT}s; see #{paths.fetch('log_path')}")
      end

      def create_databases_and_user
        statements = []
        statements << "CREATE ROLE #{identifier(username)} LOGIN" unless role_exists?
        statements << "ALTER ROLE #{identifier(username)} WITH PASSWORD #{literal(password.to_s)}" if password_env && password
        [database, test_database].compact.each do |db|
          statements << "CREATE DATABASE #{identifier(db)} OWNER #{identifier(username)}" unless database_exists?(db)
        end
        [database, test_database].compact.each do |db|
          statements << "GRANT ALL PRIVILEGES ON DATABASE #{identifier(db)} TO #{identifier(username)}"
        end
        statements.each { |statement| run_sql(statement) }
      end

      def role_exists?
        catalog_exists?("SELECT 1 FROM pg_roles WHERE rolname = #{literal(username)}")
      end

      def database_exists?(db)
        catalog_exists?("SELECT 1 FROM pg_database WHERE datname = #{literal(db)}")
      end

      def catalog_exists?(sql)
        output, status = Open3.capture2(client_env, binary('psql'), "--host=#{paths.fetch('socket_dir')}", "--port=#{port}", '--username=postgres', '--tuples-only', '--no-align', '--command', sql)
        raise(Abort, "services.#{@name} failed to query PostgreSQL catalog; see #{paths.fetch('log_path')}") unless status.success?
        !output.strip.empty?
      end

      def run_sql(sql)
        ok = system(client_env, binary('psql'), "--host=#{paths.fetch('socket_dir')}", "--port=#{port}", '--username=postgres', '--command', sql, out: File::NULL, err: paths.fetch('log_path'))
        raise(Abort, "services.#{@name} failed to create databases or grants; see #{paths.fetch('log_path')}") unless ok
      end

      def identifier(value)
        "\"#{value.to_s.gsub('"', '""')}\""
      end

      def literal(value)
        "'#{value.to_s.gsub("'", "''")}'"
      end

      def base_record(existing)
        now = timestamp
        (existing || {}).merge(
          'name' => @name,
          'type' => 'postgres',
          'state' => existing&.fetch('state', 'stopped') || 'stopped',
          'pid_path' => paths.fetch('pid_path'),
          'log_path' => paths.fetch('log_path'),
          'data_dir' => paths.fetch('data_dir'),
          'socket_dir' => paths.fetch('socket_dir'),
          'config_path' => paths.fetch('config_path'),
          'ports' => { @name => port },
          'datadir_initialized' => datadir_looks_initialized?,
          'ready' => existing&.fetch('ready', false) || false,
          'resolved_env' => resolved_env,
          'created_at' => existing&.fetch('created_at', now) || now,
          'updated_at' => now
        )
      end

      def paths_to_reset(record)
        if record
          %w(data_dir pid_path socket_dir config_path run_dir tmp_dir).map do |key|
            raise(Abort, "Cannot safely reset #{@name}: state is missing #{key}.") if key == 'data_dir' && !record.key?(key)

            value = record[key] || paths[key]
            raise(Abort, "Cannot safely reset #{@name}: state is missing #{key}.") if key == 'data_dir' && value.to_s.empty?

            value
          end.compact
        else
          %w(data_dir pid_path socket_dir config_path run_dir tmp_dir).map { |key| paths[key] }
        end
      end

      def socket_allocation_path
        paths.fetch('socket_dir')
      end

      def socket_dir
        File.join(socket_root, short_instance_id, safe_service_name)
      end

      def record_from_service(service)
        return nil unless service
        Record.new(
          key: @name,
          name: @name,
          pid: service['pid'] && Integer(service['pid']),
          command: 'postgres',
          log_path: service['log_path'],
          pid_path: service['pid_path']
        )
      end

      def database_url(db)
        user = username ? "#{username}@" : ''
        "postgresql://#{user}#{HOST}:#{port}/#{db}" if db && port
      end

      def remove_stale_runtime_files
        FileUtils.rm_f(paths.fetch('pid_path'))
        FileUtils.rm_f(File.join(paths.fetch('socket_dir'), ".s.PGSQL.#{port}"))
      end

      def binary_engine_name
        'PostgreSQL'
      end
    end
  end
end
