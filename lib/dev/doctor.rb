require 'dev'
require 'shellwords'

module Dev
  class Doctor
    Finding = Struct.new(:status, :message, :detail, keyword_init: true)

    DEFAULT_COMMANDS = Dev::ContextualResolver::DEFAULT_COMMANDS
    SHELL_META = /[\n|&;<>$`(){}\[\]*?~]/
    SHELL_BUILTINS = %w(alias bg break cd command continue eval exec exit export false fg for function getopts hash if jobs kill let local popd printf pushd pwd read readonly return set shift test then true type ulimit umask unset until while).freeze

    def initialize(dir = Dir.pwd, env = ENV.to_h)
      @dir = dir
      @env = env
      @findings = []
    end

    def call
      project = discover_project
      return @findings unless project

      config = load_config(project)
      return @findings unless config

      check_nix_signal
      check_commands(project, config)
      check_up(project, config)
      check_services(project)
      check_state_root(project)
      @findings
    end

    private

    def discover_project
      project = Dev::Project.current(@dir)
      add(:ok, 'Project discovered', project.dir)
      project
    rescue Dev::Project::NoProject
      add(:error, 'No dev.yml found', 'Run from a project directory or add dev.yml to the project root.')
      nil
    end

    def load_config(project)
      config = project.config
      add(:ok, 'dev.yml parsed')
      config
    rescue Dev::Abort => e
      add(:error, 'dev.yml could not be parsed', e.message)
      nil
    rescue Psych::SyntaxError => e
      add(:error, 'dev.yml could not be parsed', e.message)
      nil
    end

    def check_nix_signal
      if @env['IN_NIX_SHELL'] || @env['NIX_PROFILES'] || @env.values.any? { |value| value.to_s.include?('/nix/store') }
        add(:ok, 'Nix environment signal detected')
      else
        add(:warn, 'No Nix environment signal detected', 'Run dev from nix develop or another Nix-backed activation if this project depends on Nix-provided tools.')
      end
    end

    def check_commands(project, config)
      command_entries(config).each do |label, sh|
        check_shell(project, sh, label)
      end
    end

    def command_entries(config)
      entries = []
      DEFAULT_COMMANDS.each do |name|
        next unless config.key?(name)
        collect_command_config(entries, name, config[name])
      end

      commands = config.fetch('commands', {})
      unless commands.is_a?(Hash)
        add(:error, '`commands` must be a map')
        return entries
      end

      commands.each do |name, command_config|
        collect_command_config(entries, name, command_config)
      end
      entries
    end

    def collect_command_config(entries, name, config)
      case config
      when String
        entries << ["command #{name}", config]
      when Hash
        entries << ["command #{name}", config['run']] if config['run']
        subcommands = config.fetch('subcommands', {})
        unless subcommands.is_a?(Hash)
          add(:error, "command #{name} subcommands must be a map")
          return
        end

        subcommands.each do |subcommand, subconfig|
          entries << ["command #{name} #{subcommand}", subconfig['run']] if subconfig.is_a?(Hash) && subconfig['run']
        end
      else
        add(:error, "command #{name} has unsupported config")
      end
    end

    def check_up(project, config)
      up = config['up']
      return add(:warn, '`up` is not configured', 'dev up will not run until dev.yml defines up.') unless up

      case up
      when String
        nil
      when Array
        up[0...-1].each { |step| check_up_setup_step(project, step, 'up') }
      when Hash
        normalize_steps(up['services']).each { |step| check_up_start_step(project, step, 'up.services') }
        %w(dependencies build steps).each do |section|
          normalize_steps(up[section]).each { |step| check_up_setup_step(project, step, "up.#{section}") }
        end
      else
        add(:error, '`up` has unsupported shape', '`up` must be a string, array, or map.')
      end
    end

    def normalize_steps(steps)
      case steps
      when nil
        []
      when Array
        steps
      else
        [steps]
      end
    end

    def check_up_setup_step(project, step, section)
      case step
      when String
        if project.command_config(step)
          sh, = project.resolve_command(step)
          check_shell(project, sh, "#{section} command #{step}")
        else
          check_shell(project, step, section)
        end
      when Hash
        if step['command']
          check_command_reference(project, step['command'], section)
        elsif step['run']
          check_shell(project, step['run'], section)
        else
          add(:error, "#{section} step is invalid", 'Expected command or run.')
        end
      else
        add(:error, "#{section} step is invalid", step.inspect)
      end
    end

    def check_up_start_step(project, step, section)
      case step
      when String
        if project.service_config(step)
          add(:ok, "#{section} references service #{step}")
        elsif project.command_config(step)
          sh, = project.resolve_command(step)
          check_shell(project, sh, "#{section} command #{step}")
        else
          check_shell(project, step, section)
        end
      when Hash
        if step['service']
          check_service_reference(project, step['service'], section)
        elsif step['command']
          check_command_reference(project, step['command'], section)
        elsif step['run']
          check_shell(project, step['run'], section)
        else
          add(:error, "#{section} step is invalid", 'Expected service, command, or run.')
        end
      else
        add(:error, "#{section} step is invalid", step.inspect)
      end
    end

    def check_command_reference(project, name, section)
      sh, = project.resolve_command(name.to_s)
      check_shell(project, sh, "#{section} command #{name}")
    rescue Dev::Abort
      add(:error, "#{section} references missing command #{name}")
    end

    def check_service_reference(project, name, section)
      if project.service_config(name.to_s)
        add(:ok, "#{section} references service #{name}")
      else
        add(:error, "#{section} references missing service #{name}")
      end
    end

    def check_services(project)
      project.services_config.each do |name, config|
        type = config['type']
        add(:ok, "services.#{name} uses supported type #{type}")

        if type == 'process' && config['command']
          check_command_reference(project, config['command'], "services.#{name}")
        elsif type == 'process' && config['run']
          check_shell(project, config['run'], "services.#{name}")
        elsif type == 'mysql'
          check_service_binaries(name)
        end
      end
    end

    def check_service_binaries(name)
      Dev::Services::MySQL.required_binaries.each do |binary|
        if path_lookup(binary)
          add(:ok, "services.#{name} MariaDB binary found", binary)
        else
          add(:error, "services.#{name} MariaDB binary missing", binary)
        end
      end
    end

    def check_state_root(project)
      instance = Dev::Instance.for_project(project)
      parent = File.dirname(instance.state_root)
      existing = nearest_existing_parent(parent)
      if existing && File.directory?(existing) && File.writable?(existing)
        add(:ok, 'State root parent is writable', parent)
      else
        add(:error, 'State root parent is not writable', parent)
      end
    rescue SystemCallError => e
      add(:error, 'State root parent could not be checked', e.message)
    end

    def nearest_existing_parent(path)
      current = path
      until File.exist?(current)
        parent = File.dirname(current)
        return nil if parent == current
        current = parent
      end
      current
    end

    def check_shell(project, sh, label)
      if sh.to_s.strip.empty?
        add(:error, "#{label} has empty command")
        return
      end

      if complex_shell?(sh)
        add(:unknown, "#{label} uses complex shell", 'Static executable verification is limited.')
        return
      end

      words = Shellwords.split(sh)
      executable = words.first
      if executable.nil? || SHELL_BUILTINS.include?(executable)
        add(:unknown, "#{label} executable could not be checked", sh)
      elsif executable.include?('/')
        check_script(project, executable, label)
      elsif path_lookup(executable)
        add(:ok, "#{label} executable found", executable)
      else
        add(:warn, "#{label} executable not found", executable)
      end
    rescue ArgumentError
      add(:unknown, "#{label} uses complex shell", 'Static executable verification is limited.')
    end

    def complex_shell?(sh)
      sh.match?(SHELL_META)
    end

    def check_script(project, executable, label)
      path = executable.start_with?('/') ? executable : File.join(project.dir, executable)
      if File.file?(path) && File.executable?(path)
        add(:ok, "#{label} script is executable", executable)
      else
        add(:warn, "#{label} script is missing or not executable", executable)
      end
    end

    def path_lookup(executable)
      @env.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, executable)
        File.file?(path) && File.executable?(path)
      end
    end

    def add(status, message, detail = nil)
      @findings << Finding.new(status: status, message: message, detail: detail)
    end
  end
end
