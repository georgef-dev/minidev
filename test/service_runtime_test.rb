require_relative 'test_helper'
require 'json'

class ServiceRuntimeTest < Minitest::Test
  def test_refresh_clears_stale_liveness_without_deleting_logs
    with_home do
      with_project("server: sleep 5\n") do |project|
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

        Dev::ServiceRuntime.new(project).refresh

        persisted = JSON.parse(File.read(state.state_path))
        service = persisted['services'][key]
        refute service.key?('pid')
        assert_equal 'stale', service['state']
        assert File.exist?(log_path)
        refute File.exist?(pid_path)
      end
    end
  end
end
