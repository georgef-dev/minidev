require_relative 'test_helper'
require 'json'

class CommandUxTest < Minitest::Test
  def test_status_reports_no_services_for_new_instance
    with_home do
      with_project("commands: {}\n") do |project|
        Dev::Project.stub(:current, project) do
          out, = capture_io { Dev::Commands::Status.call([], 'status') }

          assert_includes out, "Instance: #{Dev::Instance.for_project(project).label}"
          assert_includes out, 'No services have been started for this instance.'
        end
      end
    end
  end

  def test_status_reports_configured_stopped_service_and_running_process
    with_home do
      with_project(<<~YAML) do |project|
        services:
          worker:
            type: process
            run: sleep 5
      YAML
        manager = Dev::ProcessManager.new(project)
        manager.start('server', 'sleep 5', [])

        Dev::Project.stub(:current, project) do
          out, = capture_io { Dev::Commands::Status.call([], 'status') }

          assert_includes out, 'worker'
          assert_includes out, 'stopped'
          assert_includes out, 'server'
          assert_includes out, 'running'
        end
      ensure
        manager&.stop
      end
    end
  end

  def test_ps_remains_process_focused
    with_home do
      with_project(<<~YAML) do |project|
        services:
          mysql:
            type: mysql
      YAML
        Dev::Project.stub(:current, project) do
          out, = capture_io { Dev::Commands::Ps.call([], 'ps') }

          assert_includes out, 'No tracked processes are running.'
          refute_includes out, 'mysql'
        end
      end
    end
  end

  def test_logs_lists_known_log_paths_and_prints_service_log
    with_home do
      with_project("server: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        record = manager.start('server', 'sleep 5', [])
        File.write(record.log_path, "hello log\n")

        Dev::Project.stub(:current, project) do
          list, = capture_io { Dev::Commands::Logs.call([], 'logs') }
          show, = capture_io { Dev::Commands::Logs.call(['server'], 'logs') }

          assert_includes list, 'server'
          assert_includes list, 'logs/server'
          assert_includes show, "Log: #{record.log_path}"
          assert_includes show, 'hello log'
        end
      ensure
        manager&.stop
      end
    end
  end

  def test_logs_unknown_and_missing_log_messages
    with_home do
      with_project(<<~YAML) do |project|
        services:
          worker:
            type: process
            run: sleep 5
      YAML
        Dev::Project.stub(:current, project) do
          missing, = capture_io { Dev::Commands::Logs.call(['worker'], 'logs') }
          error = assert_raises(Dev::Abort) { Dev::Commands::Logs.call(['redis'], 'logs') }

          assert_includes missing, 'No log file exists for worker yet.'
          assert_includes error.message, 'Unknown service: redis'
          assert_includes error.message, 'Known services: worker'
        end
      end
    end
  end

  def test_env_prints_minidev_controlled_env_and_redacts_secrets
    with_home do
      with_project(<<~YAML) do |project|
        env:
          PROJECT_ENV: configured
          DB_PASSWORD: secret
      YAML
        previous_inherited = ENV['INHERITED_SECRET']
        ENV['INHERITED_SECRET'] = 'do-not-print'

        Dev::Project.stub(:current, project) do
          out, = capture_io { Dev::Commands::Env.call([], 'env') }

          assert_includes out, 'PROJECT_ENV=configured'
          assert_includes out, 'DB_PASSWORD=<redacted>'
          assert_includes out, 'MINIDEV_INSTANCE_ID='
          refute_includes out, 'INHERITED_SECRET'
          refute_includes out, 'secret'
        end
      ensure
        ENV['INHERITED_SECRET'] = previous_inherited
      end
    end
  end

  def test_reset_requires_target_and_errors_unknown_service
    with_home do
      with_project("commands: {}\n") do |project|
        Dev::Project.stub(:current, project) do
          assert_raises(Dev::Abort) { Dev::Commands::Reset.call([], 'reset') }
          error = assert_raises(Dev::Abort) { Dev::Commands::Reset.call(['redis'], 'reset') }

          assert_includes error.message, 'Unknown service: redis'
        end
      end
    end
  end

  def test_reset_named_process_stops_and_removes_runtime_files
    with_home do
      with_project("server: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        record = manager.start('server', 'sleep 5', [])
        File.write(record.log_path, "old log\n")

        Dev::Project.stub(:current, project) do
          out, = capture_io { Dev::Commands::Reset.call(['server'], 'reset') }

          assert_includes out, 'Reset server.'
          assert_equal [], manager.ps
          refute File.exist?(record.pid_path)
          refute File.exist?(record.log_path)
        end
      end
    end
  end

  def test_reset_all_resets_configured_and_recorded_services
    with_home do
      with_project(<<~YAML) do |project|
        services:
          worker:
            type: process
            run: sleep 5
      YAML
        manager = Dev::ProcessManager.new(project)
        record = manager.start('server', 'sleep 5', [])

        Dev::Project.stub(:current, project) do
          out, = capture_io { Dev::Commands::Reset.call(['--all'], 'reset') }

          assert_includes out, 'Reset server.'
          refute File.exist?(record.log_path)
        end
      end
    end
  end
end
