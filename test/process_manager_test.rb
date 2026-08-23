require_relative 'test_helper'
require 'json'
require 'yaml'

class ProcessManagerTest < Minitest::Test
  def test_raw_command_name_accepts_optional_occurrence
    generic = Dev::ProcessManager.raw_command_name('sleep', ['5'])

    assert_match(/\Acommand\.[0-9a-f]{12}\z/, generic)
    assert_equal "#{generic}.0", Dev::ProcessManager.raw_command_name('sleep', ['5'], 0)
    assert_equal "#{generic}.1", Dev::ProcessManager.raw_command_name('sleep', ['5'], 1)
  end

  def test_start_records_process_and_ps_returns_it
    with_home do
      with_project("server: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        instance = Dev::Instance.for_project(project)
        record = manager.start('server', 'sleep 5', [])

        processes = manager.ps

        assert_equal 1, processes.size
        assert_equal 'server', processes.first.name
        assert_equal "server.development.#{instance.slugged_worktree_name}", processes.first.key
        assert_equal record.pid, processes.first.pid
        assert_equal File.join(instance.state_root, 'logs', "#{processes.first.key}.log"), processes.first.log_path
        assert File.exist?(processes.first.log_path)
        assert File.exist?(processes.first.pid_path)

        state = JSON.parse(File.read(File.join(instance.state_root, 'instance.json')))
        service = state['services'][processes.first.key]
        assert_equal 'process', service['type']
        assert_equal 'running', service['state']
        assert_nil service['ready']

        manager.stop
        manager.cleanup!
      end
    end
  end

  def test_stop_removes_process_from_registry
    with_home do
      with_project("server: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        record = manager.start('server', 'sleep 5', [])

        stopped = manager.stop(['server'])

        assert_equal ['server'], stopped.map(&:name)
        assert_equal [], manager.ps
        assert File.exist?(record.log_path)
        refute File.exist?(record.pid_path)
        manager.cleanup!
      end
    end
  end

  def test_cleanup_preserves_instance_state_dir
    with_home do
      with_project("server: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        instance = Dev::Instance.for_project(project)
        manager.start('server', 'sleep 5', [])

        manager.stop
        manager.cleanup!

        assert Dir.exist?(instance.state_root)
      end
    end
  end

  def test_ps_cleans_stale_liveness_and_preserves_log
    with_home do
      with_project("server: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        instance = Dev::Instance.for_project(project)
        state = Dev::InstanceState.new(instance)
        key = "server.development.#{instance.slugged_worktree_name}"
        log_path = File.join(instance.state_root, 'logs', "#{key}.log")
        pid_path = File.join(instance.state_root, 'pids', "#{key}.pid")

        state.mutate do |data|
          FileUtils.mkdir_p(File.dirname(log_path))
          FileUtils.mkdir_p(File.dirname(pid_path))
          File.write(log_path, "old log\n")
          File.write(pid_path, "999999\n")
          data['services'][key] = {
            'name' => key,
            'display_name' => 'server',
            'type' => 'process',
            'state' => 'running',
            'pid' => 999999,
            'command' => 'sleep 5',
            'pid_path' => pid_path,
            'log_path' => log_path,
            'ready' => nil,
          }
        end

        assert_equal [], manager.ps
        persisted = JSON.parse(File.read(state.state_path))
        service = persisted['services'][key]
        refute service.key?('pid')
        assert_equal 'stale', service['state']
        assert File.exist?(log_path)
        refute File.exist?(pid_path)
      end
    end
  end

  def test_stable_names_include_named_process_raw_command_hash_and_worktree_slug
    with_home do
      Dir.mktmpdir('minidev-parent') do |parent|
        worktree_root = File.join(parent, 'My Worktree!!')
        FileUtils.mkdir_p(worktree_root)
        File.write(File.join(worktree_root, 'dev.yml'), "server: sleep 5\n")
        project = Dev::Project.new(worktree_root)
        manager = Dev::ProcessManager.new(project)
        instance = Dev::Instance.for_project(project)

        named = manager.start('server', 'sleep 5', [])
        raw_name = Dev::ProcessManager.raw_command_name('sleep', ['5'], 0)
        raw = manager.start(raw_name, 'sleep', ['5'])

        assert_equal 'server.development.my-worktree', named.key
        assert_match(/\Acommand\.[0-9a-f]{12}\.0\z/, raw_name)
        assert_equal "#{raw_name}.development.my-worktree", raw.key
        assert_equal 'my-worktree', instance.slugged_worktree_name
      ensure
        manager&.stop
      end
    end
  end

  def test_started_raw_command_keys_include_zero_based_occurrences
    with_home do
      Dir.mktmpdir('minidev-parent') do |parent|
        worktree_root = File.join(parent, 'My Worktree!!')
        FileUtils.mkdir_p(worktree_root)
        File.write(File.join(worktree_root, 'dev.yml'), "commands: {}\n")
        project = Dev::Project.new(worktree_root)
        manager = Dev::ProcessManager.new(project)

        first_name = Dev::ProcessManager.raw_command_name('sleep', ['5'], 0)
        second_name = Dev::ProcessManager.raw_command_name('sleep', ['5'], 1)
        first = manager.start(first_name, 'sleep', ['5'])
        second = manager.start(second_name, 'sleep', ['5'])

        assert_match(/\Acommand\.[0-9a-f]{12}\.0\.development\.my-worktree\z/, first.key)
        assert_match(/\Acommand\.[0-9a-f]{12}\.1\.development\.my-worktree\z/, second.key)
      ensure
        manager&.stop
      end
    end
  end

  def test_legacy_pid_tmp_is_read_but_not_destroyed
    with_home do
      with_project("server: sleep 5\n") do |project|
        dev_dir = File.join(project.dir, '.dev')
        FileUtils.mkdir_p(dev_dir)
        pid = Process.spawn('/bin/bash', '-c', 'sleep 5', pgroup: true, out: File::NULL, err: File::NULL)
        Process.detach(pid)
        legacy_path = File.join(dev_dir, 'pid.tmp')
        File.write(legacy_path, YAML.dump([{ 'name' => 'legacy', 'pid' => pid, 'command' => 'sleep 5' }]))

        manager = Dev::ProcessManager.new(project)
        assert_equal ['legacy'], manager.ps.map(&:name)
        manager.stop(['legacy'])
        assert File.exist?(legacy_path)
      end
    end
  end
end
