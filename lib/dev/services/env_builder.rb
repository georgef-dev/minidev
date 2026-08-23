require 'dev'

module Dev
  module Services
    class EnvBuilder
      def initialize(project, instance: Instance.for_project(project), state: InstanceState.new(instance), env: ENV.to_h)
        @project = project
        @instance = instance
        @state = state
        @env = env
      end

      def command_env(extra = {})
        stringify_hash(@env)
          .merge(stringify_hash(@project.config.fetch('env', {})))
          .merge(resolved_env)
          .merge(runtime_secret_env)
          .merge(stringify_hash(extra))
      end

      def resolved_env
        @instance.metadata_env.merge(service_env_from_state)
      end

      def persist!
        env = resolved_env
        @state.mutate { |data| data['resolved_env'] = env }
        env
      end

      private

      def service_env_from_state
        data = @state.ensure!
        data.fetch('services', {}).values.reduce({}) do |env, service|
          env.merge(stringify_hash(service.fetch('resolved_env', {})))
        end
      end

      def runtime_secret_env
        @project.services_config.each_with_object({}) do |_name_config, env|
          _name, config = _name_config
          next unless config['type'] == 'mysql' && config['password_env'] && @env.key?(config['password_env'])

          env['MYSQL_PASSWORD'] = @env.fetch(config['password_env']).to_s
        end
      end

      def stringify_hash(hash)
        hash.to_h.each_with_object({}) do |(key, value), env|
          env[key.to_s] = value.to_s
        end
      end
    end
  end
end
