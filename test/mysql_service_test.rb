require_relative 'test_helper'
require 'json'
require 'socket'

class MySQLServiceTest < Minitest::Test
  def test_defaults_use_safe_project_slug
    with_home do
      Dir.mktmpdir('minidev-parent') do |parent|
        project_dir = File.join(parent, '123 My App!')
        FileUtils.mkdir_p(project_dir)
        File.write(File.join(project_dir, 'dev.yml'), mysql_config)
        project = Dev::Project.new(project_dir)
        service = Dev::Services::MySQL.new(project, 'mysql', project.service_config('mysql'))

        env = service.resolved_env

        assert_equal 'project_123_my_app_development', env['MYSQL_DATABASE']
        assert_equal 'project_123_my_app_test', env['MYSQL_TEST_DATABASE']
        assert_equal 'project_123_my_app', env['MYSQL_USERNAME']
      end
    end
  end

  def test_path_derivation_and_generated_config_contents
    with_home do
      with_project(mysql_config) do |project|
        service = mysql_service(project, env: fake_mariadb_env)
        service.prepare
        instance = Dev::Instance.for_project(project)

        paths = service.paths
        assert_equal File.join(instance.state_root, 'data', 'mysql'), paths['data_dir']
        assert_equal File.join(instance.state_root, 'logs', 'mysql.log'), paths['log_path']
        assert_equal File.join(instance.state_root, 'pids', 'mysql.pid'), paths['pid_path']
        assert_equal File.join('/tmp', 'minidev', instance.instance_id[0, 15], 'mysql.sock'), paths['socket_path']
        assert_operator paths['socket_path'].bytesize, :<=, 103
        assert_equal File.join(instance.state_root, 'run', 'mysql', 'my.cnf'), paths['config_path']

        config = File.read(paths['config_path'])
        assert_includes config, "datadir=#{paths['data_dir']}"
        assert_includes config, "socket=#{paths['socket_path']}"
        assert_includes config, 'bind-address=127.0.0.1'
        assert_includes config, "pid-file=#{paths['pid_path']}"
        assert_includes config, "log-error=#{paths['log_path']}"
      end
    end
  end

  def test_prepare_reports_progress_for_long_running_phases
    with_home do
      with_project(mysql_config) do |project|
        messages = []
        service = Dev::Services::MySQL.new(project, 'mysql', project.service_config('mysql'), env: fake_mariadb_env, reporter: ->(message) { messages << message })

        service.prepare

        assert_includes messages, 'checking MariaDB service mysql'
        assert_includes messages, 'allocating MariaDB paths and port for mysql'
        assert_includes messages, 'writing MariaDB config for mysql'
        assert_includes messages, 'initializing MariaDB datadir for mysql'
      end
    end
  end

  def test_env_construction_does_not_persist_password
    with_home do
      with_project(<<~YAML) do |project|
        services:
          mysql:
            type: mysql
            database: app_development
            test_database: app_test
            username: app
            password_env: APP_DB_PASSWORD
      YAML
        env = fake_mariadb_env('APP_DB_PASSWORD' => 'secret')
        service = mysql_service(project, env: env)
        service.prepare

        runtime_env = service.resolved_env(include_password: true)
        assert_equal 'secret', runtime_env['MYSQL_PASSWORD']
        assert_equal 'mysql2://app@127.0.0.1:#{port}/app_development'.sub('#{port}', runtime_env['MYSQL_PORT']), runtime_env['DATABASE_URL']
        refute_includes runtime_env['DATABASE_URL'], 'secret'

        persisted = JSON.parse(File.read(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path))
        persisted_env = persisted['services']['mysql']['resolved_env']
        refute persisted_env.key?('MYSQL_PASSWORD')
        refute JSON.generate(persisted).include?('secret')
      end
    end
  end

  def test_env_builder_adds_mysql_password_at_runtime_only
    with_home do
      with_project(<<~YAML) do |project|
        services:
          mysql:
            type: mysql
            password_env: APP_DB_PASSWORD
      YAML
        service = mysql_service(project, env: fake_mariadb_env('APP_DB_PASSWORD' => 'runtime-secret'))
        service.prepare

        command_env = Dev::Services::EnvBuilder.new(project, env: { 'APP_DB_PASSWORD' => 'runtime-secret' }).command_env
        persisted = JSON.parse(File.read(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path))

        assert_equal 'runtime-secret', command_env['MYSQL_PASSWORD']
        refute persisted['resolved_env'].key?('MYSQL_PASSWORD')
        refute JSON.generate(persisted).include?('runtime-secret')
      end
    end
  end

  def test_missing_password_env_aborts_before_datadir_mutation
    with_home do
      with_project(<<~YAML) do |project|
        services:
          mysql:
            type: mysql
            password_env: APP_DB_PASSWORD
      YAML
        service = mysql_service(project, env: fake_mariadb_env)
        error = assert_raises(Dev::Abort) { service.prepare }

        assert_includes error.message, 'APP_DB_PASSWORD'
        refute Dir.exist?(service.paths['data_dir'])
      end
    end
  end

  def test_missing_binary_failure_happens_before_datadir_mutation
    with_home do
      with_project(mysql_config) do |project|
        service = mysql_service(project, env: { 'PATH' => '' })
        error = assert_raises(Dev::Abort) { service.prepare }

        assert_includes error.message, 'mariadbd'
        refute Dir.exist?(service.paths['data_dir'])
      end
    end
  end

  def test_port_allocation_persists_and_reuses_free_port
    with_home do
      with_project(mysql_config) do |project|
        service = mysql_service(project, env: fake_mariadb_env)
        service.prepare
        first_port = persisted_port(project)

        service.prepare

        assert_equal first_port, persisted_port(project)
      end
    end
  end

  def test_port_conflict_replaces_non_instance_allocation
    with_home do
      with_project(mysql_config) do |project|
        service = mysql_service(project, env: fake_mariadb_env)
        service.prepare
        first_port = persisted_port(project)

        TCPServer.open('127.0.0.1', first_port) do
          service.prepare
        end

        refute_equal first_port, persisted_port(project)
      end
    end
  end

  def test_missing_config_is_regenerated_and_stale_pid_socket_are_cleaned
    with_home do
      with_project(mysql_config) do |project|
        service = mysql_service(project, env: fake_mariadb_env)
        service.prepare
        FileUtils.rm_f(service.paths['config_path'])
        File.write(service.paths['pid_path'], "999999\n")
        FileUtils.touch(service.paths['socket_path'])
        state = Dev::InstanceState.new(Dev::Instance.for_project(project))
        state.mutate do |data|
          data['services']['mysql']['pid'] = 999999
          data['services']['mysql']['state'] = 'running'
        end

        service.refresh
        service.prepare

        assert File.exist?(service.paths['config_path'])
        persisted = JSON.parse(File.read(state.state_path))
        refute persisted['services']['mysql'].key?('pid')
        assert_equal 'stopped', persisted['services']['mysql']['state']
      end
    end
  end

  def test_reset_removes_owned_mysql_state_and_preserves_log
    with_home do
      with_project(mysql_config) do |project|
        service = mysql_service(project, env: fake_mariadb_env)
        service.prepare
        File.write(service.paths['log_path'], "mysql log\n")
        File.write(service.paths['pid_path'], "999999\n")
        FileUtils.touch(service.paths['socket_path'])

        service.reset

        refute Dir.exist?(service.paths['data_dir'])
        refute File.exist?(service.paths['pid_path'])
        refute File.exist?(service.paths['socket_path'])
        refute File.exist?(service.paths['config_path'])
        assert File.exist?(service.paths['log_path'])
      end
    end
  end

  def test_reset_refuses_mysql_record_missing_data_dir
    with_home do
      with_project(mysql_config) do |project|
        service = mysql_service(project, env: fake_mariadb_env)
        service.prepare
        state = Dev::InstanceState.new(Dev::Instance.for_project(project))
        state.mutate { |data| data['services']['mysql'].delete('data_dir') }

        error = assert_raises(Dev::Abort) { service.reset }

        assert_includes error.message, 'state is missing data_dir'
      end
    end
  end

  def test_doctor_checks_mariadb_binaries
    with_project(mysql_config) do |project|
      findings = Dev::Doctor.new(project.dir, fake_mariadb_env).call

      Dev::Services::MySQL.required_binaries.each do |binary|
        assert findings.any? { |finding| finding.status == :ok && finding.message.include?('MariaDB binary found') && finding.detail == binary }
      end
    end
  end

  def test_integration_start_and_stop_with_real_mariadb_if_available
    missing = Dev::Services::MySQL.required_binaries.reject { |binary| system({ 'PATH' => ENV.fetch('PATH', '') }, 'which', binary, out: File::NULL, err: File::NULL) }
    skip "MariaDB integration skipped; missing binaries: #{missing.join(', ')}" unless missing.empty?

    with_home do
      with_project(mysql_config) do |project|
        service = mysql_service(project)
        record = service.start

        assert record.pid
        assert service.healthcheck
        assert_equal 'running', JSON.parse(File.read(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path))['services']['mysql']['state']
      ensure
        service&.stop
      end
    end
  end

  private

  def mysql_config
    <<~YAML
      services:
        mysql:
          type: mysql
    YAML
  end

  def mysql_service(project, env: ENV.to_h)
    Dev::Services::MySQL.new(project, 'mysql', project.service_config('mysql'), env: env)
  end

  def persisted_port(project)
    state = JSON.parse(File.read(Dev::InstanceState.new(Dev::Instance.for_project(project)).state_path))
    state['allocations']['ports']['mysql']['port']
  end

  def fake_mariadb_env(extra = {})
    dir = Dir.mktmpdir('minidev-fake-mariadb')
    Dev::Services::MySQL.required_binaries.each do |binary|
      path = File.join(dir, binary)
      File.write(path, fake_binary_script(binary))
      FileUtils.chmod(0o755, path)
    end
    { 'PATH' => dir }.merge(extra)
  end

  def fake_binary_script(binary)
    if binary == 'mariadb-install-db'
      <<~SH
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            --datadir=*) datadir="${arg#--datadir=}" ;;
          esac
        done
        /bin/mkdir -p "$datadir/mysql"
      SH
    else
      "#!/bin/sh\nexit 0\n"
    end
  end
end
