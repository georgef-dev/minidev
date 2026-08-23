require_relative 'test_helper'
require 'json'

class EnvBuilderTest < Minitest::Test
  def test_command_env_precedence_and_string_conversion
    with_home do
      with_project(<<~YAML) do |project|
        env:
          SHARED: project
          PROJECT_NUMBER: 123
          MINIDEV_ENVIRONMENT: project-override
      YAML
        previous_shared = ENV['SHARED']
        ENV['SHARED'] = 'inherited'

        builder = Dev::Services::EnvBuilder.new(project)
        env = builder.command_env('SHARED' => :service, 'SERVICE_NUMBER' => 456)

        assert_equal 'service', env['SHARED']
        assert_equal '123', env['PROJECT_NUMBER']
        assert_equal '456', env['SERVICE_NUMBER']
        assert_equal 'development', env['MINIDEV_ENVIRONMENT']
        assert env['MINIDEV_INSTANCE_ID'].is_a?(String)
        assert env.values.all? { |value| value.is_a?(String) }
      ensure
        ENV['SHARED'] = previous_shared
      end
    end
  end

  def test_persisted_resolved_env_excludes_inherited_env
    with_home do
      with_project(<<~YAML) do |project|
        env:
          PROJECT_ONLY: value
      YAML
        previous_secret = ENV['MINIDEV_TEST_SECRET']
        ENV['MINIDEV_TEST_SECRET'] = 'do-not-persist'

        instance = Dev::Instance.for_project(project)
        Dev::Services::EnvBuilder.new(project, instance: instance).persist!

        state = JSON.parse(File.read(File.join(instance.state_root, 'instance.json')))
        refute state['resolved_env'].key?('MINIDEV_TEST_SECRET')
        refute state['resolved_env'].key?('PROJECT_ONLY')
        assert_equal instance.instance_id, state['resolved_env']['MINIDEV_INSTANCE_ID']
      ensure
        ENV['MINIDEV_TEST_SECRET'] = previous_secret
      end
    end
  end
end
