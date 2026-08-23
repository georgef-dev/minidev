require_relative 'test_helper'

class DoctorTest < Minitest::Test
  def test_missing_project_reports_actionable_error
    Dir.mktmpdir('minidev-no-project') do |dir|
      findings = Dev::Doctor.new(dir, clean_env).call

      assert_finding findings, :error, 'No dev.yml found'
    end
  end

  def test_malformed_config_reports_actionable_error
    Dir.mktmpdir('minidev-bad-config') do |dir|
      File.write(File.join(dir, 'dev.yml'), "up:\n  - [")

      findings = Dev::Doctor.new(dir, clean_env).call

      assert_finding findings, :error, 'dev.yml could not be parsed'
    end
  end

  def test_malformed_command_config_reports_actionable_error
    with_project("commands: worker\n") do |project|
      findings = Dev::Doctor.new(project.dir, clean_env).call

      assert_finding findings, :error, '`commands` must be a map'
    end
  end

  def test_missing_up_command_and_service_references_report_errors
    with_project(<<~YAML) do |project|
      up:
        dependencies:
          - command: missing
        services:
          - service: missing_service
    YAML
      findings = Dev::Doctor.new(project.dir, clean_env).call

      assert_finding findings, :error, 'up.dependencies references missing command missing'
      assert_finding findings, :error, 'up.services references missing service missing_service'
    end
  end

  def test_process_service_missing_command_reference_reports_error
    with_project(<<~YAML) do |project|
      services:
        worker:
          type: process
          command: worker
    YAML
      findings = Dev::Doctor.new(project.dir, clean_env).call

      assert_finding findings, :error, 'services.worker references missing command worker'
    end
  end

  def test_simple_missing_binary_and_script_report_warnings
    with_project(<<~YAML) do |project|
      build: missing-tool build
      test: bin/test
    YAML
      findings = Dev::Doctor.new(project.dir, clean_env('PATH' => '')).call

      assert_finding findings, :warn, 'command build executable not found'
      assert_finding findings, :warn, 'command test script is missing or not executable'
    end
  end

  def test_simple_existing_script_reports_ok
    Dir.mktmpdir('minidev-script') do |dir|
      bin = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin)
      script = File.join(bin, 'test')
      File.write(script, "#!/bin/sh\n")
      FileUtils.chmod(0o755, script)
      File.write(File.join(dir, 'dev.yml'), "test: bin/test\n")

      findings = Dev::Doctor.new(dir, clean_env).call

      assert_finding findings, :ok, 'command test script is executable'
    end
  end

  def test_complex_shell_reports_unknown
    with_project("test: bundle exec rake test | tee out\n") do |project|
      findings = Dev::Doctor.new(project.dir, clean_env).call

      assert_finding findings, :unknown, 'command test uses complex shell'
    end
  end

  def test_no_nix_signal_reports_warning
    with_project("test: ruby -v\n") do |project|
      findings = Dev::Doctor.new(project.dir, clean_env).call

      assert_finding findings, :warn, 'No Nix environment signal detected'
    end
  end

  def test_nix_signal_reports_ok
    with_project("test: ruby -v\n") do |project|
      findings = Dev::Doctor.new(project.dir, clean_env('IN_NIX_SHELL' => 'pure')).call

      assert_finding findings, :ok, 'Nix environment signal detected'
    end
  end

  def test_mysql_binary_checks_report_missing_mariadb_binaries
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: mysql
    YAML
      findings = Dev::Doctor.new(project.dir, clean_env).call

      assert_finding findings, :error, 'services.mysql MariaDB binary missing'
    end
  end

  def test_doctor_does_not_mutate_instance_service_records
    with_home do
      with_project("server: sleep 5\n") do |project|
        instance = Dev::Instance.for_project(project)
        state_path = File.join(instance.state_root, 'instance.json')

        Dev::Doctor.new(project.dir, clean_env).call

        refute File.exist?(state_path)
      end
    end
  end

  def test_doctor_command_is_registered
    assert_includes Dev::Commands::Registry.resolved_commands.keys, 'doctor'
  end

  def test_doctor_command_prints_report_and_aborts_on_errors
    Dir.mktmpdir('minidev-no-project') do |dir|
      command = Dev::Commands::Doctor.new
      Dir.chdir(dir) do
        out, = capture_io do
          assert_raises(Dev::Abort) { command.call([], 'doctor') }
        end

        assert_includes out, 'ERROR: No dev.yml found'
      end
    end
  end

  private

  def clean_env(extra = {})
    { 'PATH' => ENV.fetch('PATH', '') }.merge(extra)
  end

  def assert_finding(findings, status, message)
    assert findings.any? { |finding| finding.status == status && finding.message.include?(message) },
      "Expected #{status} finding including #{message.inspect}, got #{findings.map { |f| [f.status, f.message, f.detail] }.inspect}"
  end
end
