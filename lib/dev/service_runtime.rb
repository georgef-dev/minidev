require 'dev'
require 'fileutils'

module Dev
  class ServiceRuntime
    MANAGED_SERVICE_ADAPTERS = {
      'mysql' => Services::MySQL,
      'postgres' => Services::Postgres,
    }.freeze
    private_constant :MANAGED_SERVICE_ADAPTERS

    def self.managed_service_type?(type)
      MANAGED_SERVICE_ADAPTERS.key?(type)
    end

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
      managed_services.each(&:refresh)
      @env_builder.persist!
    end

    def start_managed_service(name)
      service = managed_service(name)
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
      managed_records, stopped_managed_names = stop_managed_services(names)
      process_names = names - stopped_managed_names
      process_arg = names.empty? ? nil : process_names
      records = managed_records.compact + @process_manager.stop(process_arg)
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
      if managed_service_name?(name)
        result = managed_service(name).reset
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

    def managed_service_name?(name)
      config = @project.service_config(name)
      return true if config && MANAGED_SERVICE_ADAPTERS.key?(config['type'])

      MANAGED_SERVICE_ADAPTERS.key?(@state.ensure!.fetch('services', {}).fetch(name, {})['type'])
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

    def managed_services
      @project.services_config.filter_map do |name, config|
        adapter = MANAGED_SERVICE_ADAPTERS[config['type']]
        next unless adapter

        adapter.new(@project, name, config, instance: @instance, state: @state, reporter: @reporter)
      end
    end

    def managed_service(name)
      config = @project.service_config(name.to_s)
      recorded_type = @state.ensure!.fetch('services', {}).fetch(name.to_s, {})['type']
      config ||= { 'type' => recorded_type } if MANAGED_SERVICE_ADAPTERS.key?(recorded_type)
      adapter = config && MANAGED_SERVICE_ADAPTERS[config['type']]
      raise_unknown_service(name) unless adapter

      adapter.new(@project, name, config, instance: @instance, state: @state, reporter: @reporter)
    end

    def stop_managed_services(names)
      targets = managed_services.select { |service| names.empty? || names.include?(service.name) }
      [targets.map(&:stop), targets.map(&:name)]
    end
  end
end
