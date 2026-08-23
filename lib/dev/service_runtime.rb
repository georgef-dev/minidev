require 'dev'
require 'fileutils'

module Dev
  class ServiceRuntime
    def initialize(project, reporter: nil)
      @project = project
      @instance = Instance.for_project(project)
      @state = InstanceState.new(@instance)
      @reporter = reporter
      @env_builder = Services::EnvBuilder.new(project, instance: @instance, state: @state)
      @process_manager = ProcessManager.new(project, instance: @instance, state: @state)
    end

    attr_reader :env_builder, :instance, :state

    def refresh
      @process_manager.ps
      mysql_services.each(&:refresh)
      @env_builder.persist!
    end

    def start_mysql(name)
      service = mysql_service(name)
      record = service.start
      @env_builder.persist!
      record
    end

    def start_process(name, sh, args, service_env: {})
      refresh
      record = @process_manager.start(name, sh, args, env: @env_builder.command_env(service_env))
      persist_process_service_env(record.key, service_env)
      @env_builder.persist!
      record
    end

    def stop(names = nil)
      names = Array(names).map(&:to_s)
      mysql_records, stopped_mysql_names = stop_mysql_services(names)
      process_names = names - stopped_mysql_names
      process_arg = names.empty? ? nil : process_names
      records = mysql_records.compact + @process_manager.stop(process_arg)
      @env_builder.persist!
      records
    end

    def ps
      records = @process_manager.ps
      @env_builder.persist!
      records
    end

    def services
      refresh
      configured = @project.services_config.keys
      recorded = @state.ensure!.fetch('services', {}).keys
      names = (configured + recorded.map { |key| service_display_name(key) }).uniq

      names.map { |name| service_summary(name) }
    end

    def service(name)
      services.find { |summary| summary['name'] == name.to_s || summary['key'] == name.to_s }
    end

    def controlled_env
      refresh
      stringify_hash(@project.config.fetch('env', {})).merge(@env_builder.resolved_env)
    end

    def known_service_names
      configured = @project.services_config.keys
      recorded = @state.ensure!.fetch('services', {}).map { |_key, service| service['display_name'] || service['name'] }
      (configured + recorded.compact).uniq
    end

    def reset(names)
      names = Array(names).map(&:to_s)
      raise(Abort, '`dev reset` requires a service name or --all') if names.empty?

      names.flat_map { |name| reset_one(name) }
    ensure
      @env_builder.persist! if @env_builder
    end

    def cleanup!
      @process_manager.cleanup!
    end

    private

    def persist_process_service_env(key, env)
      return if env.empty?

      @state.mutate do |data|
        service = data['services'][key]
        service['env'] = stringify_hash(env) if service
      end
    end

    def stringify_hash(hash)
      hash.to_h.each_with_object({}) { |(key, value), out| out[key.to_s] = value.to_s }
    end

    def reset_one(name)
      if mysql_service_name?(name)
        result = mysql_service(name).reset
        return result ? [result] : []
      end

      reset_process(name)
    end

    def reset_process(name)
      data = @state.ensure!
      key, service = data.fetch('services', {}).find { |record_key, record| record_key == name || record['display_name'] == name || record['name'] == name }
      raise_unknown_service(name) unless service || @project.service_config(name)
      return [] unless service

      stopped = service['pid'] ? stop([name]) : []
      log_path = service['log_path']
      pid_path = service['pid_path']
      assert_owned_path!(log_path) if log_path
      assert_owned_path!(pid_path) if pid_path
      FileUtils.rm_f(pid_path) if pid_path
      FileUtils.rm_f(log_path) if log_path
      @state.mutate { |state_data| state_data['services'].delete(key) }
      stopped + [ProcessManager::Record.new(key: key, name: service['display_name'] || service['name'] || name, pid: nil, command: service['command'], log_path: log_path, pid_path: pid_path)]
    end

    def assert_owned_path!(path)
      expanded = File.expand_path(path)
      root = File.expand_path(@instance.state_root)
      return if expanded == root || expanded.start_with?(root + File::SEPARATOR)

      raise(Abort, "Cannot safely reset service: path is outside state root: #{path}")
    end

    def mysql_service_name?(name)
      config = @project.service_config(name)
      return true if config && config['type'] == 'mysql'

      @state.ensure!.fetch('services', {}).fetch(name, {})['type'] == 'mysql'
    end

    def service_display_name(key)
      service = @state.ensure!.fetch('services', {})[key] || {}
      service['display_name'] || service['name'] || key
    end

    def service_summary(name)
      data = @state.ensure!
      config = @project.service_config(name)
      key, record = data.fetch('services', {}).find { |record_key, service| record_key == name || service['display_name'] == name || service['name'] == name }
      type = (record && record['type']) || (config && config['type']) || 'process'
      allocation = data.fetch('allocations', {}).fetch('ports', {})[name]
      {
        'key' => key || name,
        'name' => (record && (record['display_name'] || record['name'])) || name,
        'type' => type,
        'state' => record_state(record),
        'ready' => ready_value(record, type),
        'pid' => record && record['pid'],
        'port' => record_port(record) || (allocation && allocation['port']),
        'log_path' => record && record['log_path'],
        'record' => record,
      }
    end

    def record_state(record)
      return 'stopped' unless record
      return 'partial' unless record['type'] && record['state']

      record['state'] || 'stopped'
    end

    def ready_value(record, type)
      return '-' if type == 'process'
      return 'unknown' unless record && record.key?('ready')

      record['ready'] ? 'ready' : 'not ready'
    end

    def record_port(record)
      ports = record && record['ports']
      return unless ports.is_a?(Hash)

      first = ports.values.first
      first.is_a?(Hash) ? first['port'] : first
    end

    def raise_unknown_service(name)
      known = known_service_names
      message = "Unknown service: #{name}"
      message += "\nKnown services: #{known.join(', ')}" unless known.empty?
      raise(Abort, message)
    end

    def mysql_services
      @project.services_config.select { |_name, config| config['type'] == 'mysql' }.map { |name, config| Services::MySQL.new(@project, name, config, instance: @instance, state: @state, reporter: @reporter) }
    end

    def mysql_service(name)
      config = @project.service_config(name.to_s)
      config ||= { 'type' => 'mysql' } if @state.ensure!.fetch('services', {}).fetch(name.to_s, {})['type'] == 'mysql'
      raise_unknown_service(name) unless config && config['type'] == 'mysql'

      Services::MySQL.new(@project, name, config, instance: @instance, state: @state, reporter: @reporter)
    end

    def stop_mysql_services(names)
      targets = mysql_services.select { |service| names.empty? || names.include?(service.name) }
      [targets.map(&:stop), targets.map(&:name)]
    end
  end
end
