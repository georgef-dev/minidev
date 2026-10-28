require_relative 'test_helper'
require 'json'
require 'socket'

class PostgresServiceTest < Minitest::Test
  def test_defaults_use_safe_project_slug
    with_home do
      Dir.mktmpdir('minidev-parent') do |parent|
        project_dir = File.join(parent, '123 My App!')
        FileUtils.mkdir_p(project_dir)
        File.write(File.join(project_dir, 'dev.yml'), postgres_config)
        project = Dev::Project.new(project_dir)
        service = Dev::Services::Postgres.new(project, 'postgres', project.service_config('postgres'))

        env = service.resolved_env

        assert_equal 'project_123_my_app_development', env['POSTGRES_DATABASE']
        assert_equal 'project_123_my_app_test', env['POSTGRES_TEST_DATABASE']
        assert_equal 'project_123_my_app', env['POSTGRES_USERNAME']
      end
    end
  end

  def test_path_derivation_and_generated_config_contents
    with_home do
      with_project(postgres_config) do |project|
        service = postgres_service(project, env: fake_postgres_env)
        service.prepare
        instance = Dev::Instance.for_project(project)

        paths = service.paths
        assert_equal File.join(instance.state_root, 'data', 'postgres'), paths['data_dir']
        assert_equal File.join(instance.state_root, 'logs', 'postgres.log'), paths['log_path']
        assert_equal File.join(instance.state_root, 'pids', 'postgres.pid'), paths['pid_path']
        assert_equal File.join('/tmp', 'minidev', instance.instance_id[0, 15], 'postgres'), paths['socket_dir']
        # PostgreSQL appends `/.s.PGSQL.<port>` to socket_dir to form the real bind
        # path, so the limit must cover the directory plus that worst-case suffix.
        assert_operator paths['socket_dir'].bytesize + '/.s.PGSQL.65535'.bytesize, :<=, 103
        assert_equal File.join(instance.state_root, 'run', 'postgres', 'postgresql.conf'), paths['config_path']

        config = File.read(paths['config_path'])
        assert_includes config, "data_directory = '#{paths['data_dir']}'"
        assert_includes config, "unix_socket_directories = '#{paths['socket_dir']}'"
        assert_includes config, "listen_addresses = '127.0.0.1'"
        assert_includes config, "log_destination = 'stderr'"
      end
    end
  end

  def test_long_service_name_aborts_before_port_allocation_or_datadir_work
    with_home do
      long_name = 'a' * 70
      with_project(<<~YAML) do |project|
        services:
          #{long_name}:
            type: postgres
      YAML
        service = Dev::Services::Postgres.new(project, long_name, project.service_config(long_name), env: fake_postgres_env)

        started_at = Time.now
        error = assert_raises(Dev::Abort) { service.prepare }
        elapsed = Time.now - started_at

        assert_includes error.message, 'socket path would exceed'
        assert_includes error.message, '103-byte'
        assert_includes error.message, 'use a shorter service name'
        assert_operator elapsed, :<, Dev::Services::Postgres::READINESS_TIMEOUT
        refute Dir.exist?(service.paths['data_dir'])
        refute File.exist?(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path)
      end
    end
  end

  def test_ordinary_service_name_does_not_trigger_socket_path_guard
    with_home do
      with_project(postgres_config) do |project|
        service = postgres_service(project, env: fake_postgres_env)

        service.prepare

        assert Dir.exist?(service.paths['data_dir'])
      end
    end
  end

  # The guard is an off-by-one risk, so pin both sides of the boundary. The
  # budget is derived from the real socket_dir prefix rather than assumed, so
  # this stays correct if the instance id width ever changes.
  def test_socket_path_guard_boundary_is_exact
    with_home do
      with_project(postgres_config) do |project|
        probe = Dev::Services::Postgres.new(project, "postgres", project.service_config("postgres"))
        prefix_bytes = probe.paths.fetch("socket_dir").bytesize - "postgres".bytesize
        budget = Dev::Services::Postgres::SOCKET_PATH_LIMIT - Dev::Services::Postgres::SOCKET_SUFFIX_MAX_BYTES

        longest_allowed = "a" * (budget - prefix_bytes)
        first_rejected = "a" * (budget - prefix_bytes + 1)

        assert_equal budget, service_for_name(project, longest_allowed).paths.fetch("socket_dir").bytesize
        service_for_name(project, longest_allowed, env: fake_postgres_env).prepare

        error = assert_raises(Dev::Abort) { service_for_name(project, first_rejected, env: fake_postgres_env).prepare }
        assert_includes error.message, "socket path would exceed"
      end
    end
  end

  def test_prepare_reports_progress_for_long_running_phases
    with_home do
      with_project(postgres_config) do |project|
        messages = []
        service = Dev::Services::Postgres.new(project, 'postgres', project.service_config('postgres'), env: fake_postgres_env, reporter: ->(message) { messages << message })

        service.prepare

        assert_includes messages, 'checking PostgreSQL service postgres'
        assert_includes messages, 'allocating PostgreSQL paths and port for postgres'
        assert_includes messages, 'writing PostgreSQL config for postgres'
        assert_includes messages, 'initializing PostgreSQL datadir for postgres'
      end
    end
  end

  def test_env_construction_does_not_persist_password
    with_home do
      with_project(<<~YAML) do |project|
        services:
          postgres:
            type: postgres
            database: app_development
            test_database: app_test
            username: app
            password_env: APP_DB_PASSWORD
      YAML
        env = fake_postgres_env('APP_DB_PASSWORD' => 'secret')
        service = postgres_service(project, env: env)
        service.prepare

        runtime_env = service.resolved_env(include_password: true)
        assert_equal 'secret', runtime_env['POSTGRES_PASSWORD']
        assert_equal 'postgresql://app@127.0.0.1:#{port}/app_development'.sub('#{port}', runtime_env['POSTGRES_PORT']), runtime_env['DATABASE_URL']
        refute_includes runtime_env['DATABASE_URL'], 'secret'

        persisted = JSON.parse(File.read(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path))
        persisted_env = persisted['services']['postgres']['resolved_env']
        refute persisted_env.key?('POSTGRES_PASSWORD')
        refute JSON.generate(persisted).include?('secret')
      end
    end
  end

  def test_env_without_include_password_omits_it
    with_home do
      with_project(<<~YAML) do |project|
        services:
          postgres:
            type: postgres
            password_env: APP_DB_PASSWORD
      YAML
        service = postgres_service(project, env: fake_postgres_env('APP_DB_PASSWORD' => 'secret'))
        service.prepare

        refute service.resolved_env.key?('POSTGRES_PASSWORD')
      end
    end
  end

  def test_missing_password_env_aborts_before_datadir_mutation
    with_home do
      with_project(<<~YAML) do |project|
        services:
          postgres:
            type: postgres
            password_env: APP_DB_PASSWORD
      YAML
        service = postgres_service(project, env: fake_postgres_env)
        error = assert_raises(Dev::Abort) { service.prepare }

        assert_includes error.message, 'APP_DB_PASSWORD'
        refute Dir.exist?(service.paths['data_dir'])
      end
    end
  end

  def test_missing_binary_failure_happens_before_datadir_mutation
    with_home do
      with_project(postgres_config) do |project|
        service = postgres_service(project, env: { 'PATH' => '' })
        error = assert_raises(Dev::Abort) { service.prepare }

        assert_includes error.message, 'postgres'
        refute Dir.exist?(service.paths['data_dir'])
      end
    end
  end

  def test_port_allocation_persists_and_reuses_free_port
    with_home do
      with_project(postgres_config) do |project|
        service = postgres_service(project, env: fake_postgres_env)
        service.prepare
        first_port = persisted_port(project)

        service.prepare

        assert_equal first_port, persisted_port(project)
      end
    end
  end

  def test_port_conflict_replaces_non_instance_allocation
    with_home do
      with_project(postgres_config) do |project|
        service = postgres_service(project, env: fake_postgres_env)
        service.prepare
        first_port = persisted_port(project)

        TCPServer.open('127.0.0.1', first_port) do
          service.prepare
        end

        refute_equal first_port, persisted_port(project)
      end
    end
  end

  def test_reset_removes_owned_postgres_state_and_preserves_log
    with_home do
      with_project(postgres_config) do |project|
        service = postgres_service(project, env: fake_postgres_env)
        service.prepare
        File.write(service.paths['log_path'], "postgres log\n")
        File.write(service.paths['pid_path'], "999999\n")

        service.reset

        refute Dir.exist?(service.paths['data_dir'])
        refute File.exist?(service.paths['pid_path'])
        refute Dir.exist?(service.paths['socket_dir'])
        refute File.exist?(service.paths['config_path'])
        assert File.exist?(service.paths['log_path'])

        state = JSON.parse(File.read(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path))
        refute state['services'].key?('postgres')
      end
    end
  end

  def test_reset_refuses_postgres_record_missing_data_dir
    with_home do
      with_project(postgres_config) do |project|
        service = postgres_service(project, env: fake_postgres_env)
        service.prepare
        state = Dev::InstanceState.new(Dev::Instance.for_project(project))
        state.mutate { |data| data['services']['postgres'].delete('data_dir') }

        error = assert_raises(Dev::Abort) { service.reset }

        assert_includes error.message, 'state is missing data_dir'
      end
    end
  end

  def test_doctor_checks_postgresql_binaries
    with_project(postgres_config) do |project|
      findings = Dev::Doctor.new(project.dir, fake_postgres_env).call

      Dev::Services::Postgres.required_binaries.each do |binary|
        assert findings.any? { |finding| finding.status == :ok && finding.message.include?('PostgreSQL binary found') && finding.detail == binary }
      end
    end
  end

  def test_integration_start_and_stop_with_real_postgres_if_available
    missing = Dev::Services::Postgres.required_binaries.reject { |binary| system({ 'PATH' => ENV.fetch('PATH', '') }, 'which', binary, out: File::NULL, err: File::NULL) }
    skip "PostgreSQL integration skipped; missing binaries: #{missing.join(', ')}" unless missing.empty?

    with_home do
      with_project(postgres_config) do |project|
        service = postgres_service(project)
        record = service.start

        assert record.pid
        assert service.healthcheck
        assert_equal 'running', JSON.parse(File.read(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path))['services']['postgres']['state']
      ensure
        service&.stop
      end
    end
  end

  private

  def postgres_config
    <<~YAML
      services:
        postgres:
          type: postgres
    YAML
  end

  def service_for_name(project, name, env: ENV.to_h)
    Dev::Services::Postgres.new(project, name, { "type" => "postgres" }, env: env)
  end

  def postgres_service(project, env: ENV.to_h)
    Dev::Services::Postgres.new(project, 'postgres', project.service_config('postgres'), env: env)
  end

  def persisted_port(project)
    state = JSON.parse(File.read(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path))
    state['allocations']['ports']['postgres']['port']
  end

  def fake_postgres_env(extra = {})
    dir = Dir.mktmpdir('minidev-fake-postgres')
    Dev::Services::Postgres.required_binaries.each do |binary|
      path = File.join(dir, binary)
      File.write(path, fake_binary_script(binary))
      FileUtils.chmod(0o755, path)
    end
    { 'PATH' => dir }.merge(extra)
  end

  def fake_binary_script(binary)
    if binary == 'initdb'
      <<~SH
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            --pgdata=*) pgdata="${arg#--pgdata=}" ;;
          esac
        done
        /bin/mkdir -p "$pgdata"
        /usr/bin/touch "$pgdata/PG_VERSION"
      SH
    elsif binary == 'psql'
      <<~SH
        #!/bin/sh
        exit 0
      SH
    else
      "#!/bin/sh\nexit 0\n"
    end
  end
end
