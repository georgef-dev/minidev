require_relative 'test_helper'
require 'json'

class InstanceStateTest < Minitest::Test
  def test_load_create_is_idempotent
    with_home do
      with_project("test: ruby -v\n") do |project|
        state = Dev::InstanceState.new(Dev::Instance.for_project(project))

        first = state.ensure!
        second = state.ensure!

        assert_equal first, second
        assert_equal({}, first['allocations']['ports'])
        assert_equal({}, first['allocations']['sockets'])
        assert_equal({}, first['services'])
        assert_equal first['identity']['instance_id'], first['resolved_env']['MINIDEV_INSTANCE_ID']
      end
    end
  end

  def test_unsupported_newer_schema_is_rejected
    with_home do
      with_project("test: ruby -v\n") do |project|
        state = Dev::InstanceState.new(Dev::Instance.for_project(project))
        data = state.ensure!
        data['schema'] = Dev::InstanceState::SCHEMA + 1
        File.write(state.state_path, JSON.pretty_generate(data) + "\n")

        error = assert_raises(Dev::Abort) { state.ensure! }

        assert_equal 'Unsupported instance state schema 2', error.message
      end
    end
  end

  def test_pointer_is_written_without_touching_pid_tmp
    with_home do
      with_project("test: ruby -v\n") do |project|
        dev_dir = File.join(project.dir, '.dev')
        FileUtils.mkdir_p(dev_dir)
        pid_path = File.join(dev_dir, 'pid.tmp')
        File.write(pid_path, "existing pid state\n")

        state = Dev::InstanceState.new(Dev::Instance.for_project(project))
        state.ensure!

        pointer = JSON.parse(File.read(state.pointer_path))
        assert_equal state.instance.instance_id, pointer['instance_id']
        assert_equal state.instance.state_root, pointer['state_root']
        assert_equal "existing pid state\n", File.read(pid_path)
      end
    end
  end

  def test_mutation_is_persisted_through_lock
    with_home do
      with_project("test: ruby -v\n") do |project|
        state = Dev::InstanceState.new(Dev::Instance.for_project(project))

        state.mutate do |data|
          data['allocations']['ports']['web'] = { 'port' => 12345 }
        end
        state.mutate do |data|
          data['services']['server'] = { 'name' => 'server', 'type' => 'process' }
        end

        persisted = JSON.parse(File.read(state.state_path))
        assert_equal({ 'port' => 12345 }, persisted['allocations']['ports']['web'])
        assert_equal({ 'name' => 'server', 'type' => 'process' }, persisted['services']['server'])
        assert File.exist?(state.lock_path)
      end
    end
  end
end
