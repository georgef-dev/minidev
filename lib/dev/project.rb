require('dev')
require('yaml')

module Dev
  class Project
    NoProject = Class.new(Abort)

    attr_reader :dir

    def self.current(dir = Dir.pwd)
      raise(NoProject, "no project") if dir == '/'
      return new(dir) if File.exist?("#{dir}/dev.yml")
      current(File.expand_path(File.dirname(dir)))
    end

    def initialize(dir)
      @dir = dir
    end

    def config
      @config ||= begin
        loaded = YAML.load_file("#{@dir}/dev.yml") || {}
        raise(Abort, 'dev.yml must be a map') unless loaded.is_a?(Hash)

        validate_services_config(loaded)
        warn_service_command_collisions(loaded)
        loaded
      end
    end

    def env
      ENV.to_h.merge(config['env'] || {})
    end

    def command_config(name)
      if Dev::ContextualResolver::DEFAULT_COMMANDS.include?(name) && config.key?(name)
        config[name]
      else
        config.fetch('commands', {})[name]
      end
    end

    def services_config
      config.fetch('services', {})
    end

    def service_config(name)
      services_config[name]
    end

    def resolve_command(name, args = [])
      cfg = command_config(name)
      raise(Abort, "Unknown command #{name}") unless cfg

      args = args.dup

      case cfg
      when Hash
        if cfg['subcommands']&.include?(args[0])
          [cfg['subcommands'][args.shift]['run'], args]
        elsif cfg.include?('run')
          [cfg['run'], args]
        else
          raise(Abort, "#{name} only defines subcommands, but you did not specify one to run.")
        end
      when String
        [cfg, args]
      else
        raise(Abort, "Unsupported config for #{name}")
      end
    end


    private

    def validate_services_config(cfg)
      services = cfg['services']
      return if services.nil?

      raise(Abort, '`services` must be a map') unless services.is_a?(Hash)

      services.each do |name, service|
        raise(Abort, '`services` names must be strings') unless name.is_a?(String)
        raise(Abort, "services.#{name} must be a map") unless service.is_a?(Hash)

        type = service['type']
        raise(Abort, "services.#{name}.type must be a string") unless type.is_a?(String)

        case type
        when 'process'
          validate_process_service(name, service)
        when 'mysql', 'postgres'
          validate_managed_database_service(name, service)
        else
          raise(Abort, "services.#{name}.type must be one of: process, mysql, postgres")
        end
      end

      assert_at_most_one_managed_database_type!(services)
    end

    def validate_process_service(name, service)
      assert_allowed_service_keys(name, service, %w(type command run args label env))
      has_command = service.key?('command')
      has_run = service.key?('run')
      raise(Abort, "services.#{name} must define exactly one of `command` or `run`") if has_command == has_run
      raise(Abort, "services.#{name}.command must be a string") if has_command && !service['command'].is_a?(String)
      raise(Abort, "services.#{name}.run must be a string") if has_run && !service['run'].is_a?(String)
      validate_args(name, service['args']) if service.key?('args')
      validate_label(name, service['label']) if service.key?('label')
      validate_env(name, service['env']) if service.key?('env')
    end

    def validate_managed_database_service(name, service)
      assert_allowed_service_keys(name, service, %w(type database test_database username password_env env))
      %w(database test_database username password_env).each do |key|
        next unless service.key?(key)
        raise(Abort, "services.#{name}.#{key} must be a string") unless service[key].is_a?(String)
      end
      validate_env(name, service['env']) if service.key?('env')
    end

    # Both adapters export DATABASE_URL, and EnvBuilder merges every service's
    # env in hash order, so a mixed config would make DATABASE_URL non-deterministic.
    def assert_at_most_one_managed_database_type!(services)
      types = services.values.map { |service| service['type'] }
      return unless types.include?('mysql') && types.include?('postgres')

      raise(Abort, 'dev.yml cannot define both a mysql service and a postgres service; DATABASE_URL would be ambiguous')
    end

    def assert_allowed_service_keys(name, service, allowed)
      unknown = service.keys - allowed
      raise(Abort, "services.#{name} has unsupported keys: #{unknown.join(', ')}") unless unknown.empty?
    end

    def validate_args(name, args)
      raise(Abort, "services.#{name}.args must be a list") unless args.is_a?(Array)
      raise(Abort, "services.#{name}.args must contain only strings") unless args.all? { |arg| arg.is_a?(String) }
    end

    def validate_label(name, label)
      raise(Abort, "services.#{name}.label must be a string") unless label.is_a?(String)
    end

    def validate_env(name, env)
      raise(Abort, "services.#{name}.env must be a map") unless env.is_a?(Hash)
      return if env.all? { |key, value| key.is_a?(String) && value.is_a?(String) }

      raise(Abort, "services.#{name}.env must contain only string keys and values")
    end

    def warn_service_command_collisions(cfg)
      services = cfg.fetch('services', {})
      commands = cfg.fetch('commands', {})
      return unless services.is_a?(Hash) && commands.is_a?(Hash)

      (services.keys & commands.keys).each do |name|
        puts("Warning: services.#{name} and commands.#{name} both exist; up.services resolves #{name} as a service. Use { command: #{name} } to reference the command.")
      end
    end
  end
end
