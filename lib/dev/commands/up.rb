require 'dev'

module Dev
  module Commands
    class Up < Dev::Command
      def call(args, _name)
        raise(Abort, '`dev up` does not take any arguments') unless args.empty?

        @project = Dev::Project.current
        @raw_command_occurrences = Hash.new(0)
        @service_resolver = Dev::Services::Resolver.new(@project)
        instructions, service_steps, setup_steps, _serve_steps = normalize_up(@project.config['up'])

        print_instructions(instructions)

        Dir.chdir(@project.dir) do
          puts CLI::UI.fmt('{{info:checking}} current service state')
          runtime.refresh
          puts CLI::UI.fmt('{{success:checked}} current service state')
          service_steps.each { |step| start_service(step) }
          setup_steps.each { |step| run_step(step) }
        end
      end

      def self.help
        'Run project setup, including tracked dependency services from `dev.yml`.'
      end

      private

      def normalize_up(config)
        raise(Abort, 'This project does not define `up` in dev.yml') unless config

        case config
        when String
          [[], [], [], [config]]
        when Array
          [[], [], config[0...-1], normalize_steps(config[-1])]
        when Hash
          [
            Array(config['instructions']),
            normalize_steps(config['services']),
            normalize_steps(config['dependencies']) + normalize_steps(config['build']) + normalize_steps(config['steps']),
            normalize_steps(config['serve']),
          ]
        else
          raise(Abort, '`up` must be a string, array, or hash')
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

      def print_instructions(instructions)
        return if instructions.empty?

        puts CLI::UI.fmt('{{bold:Manual setup}}')
        instructions.each { |instruction| puts "- #{instruction}" }
        puts
      end

      def run_step(step)
        puts CLI::UI.fmt("{{info:running}} #{describe_step(step)}")
        run_shell(*resolve_step(step))
      end

      def start_service(step)
        resolved = @service_resolver.resolve_start_step(step)

        return start_managed_service(resolved.name, step) if Dev::ServiceRuntime.managed_service_type?(resolved.type)

        sh = resolved.sh
        args = resolved.args
        name = tracked_name(step, sh, args, resolved)

        puts CLI::UI.fmt("{{info:starting}} #{describe_step(step)}")
        start_process(name, sh, args, resolved.env || {})
      end

      def resolve_step(step)
        case step
        when String
          if @project.command_config(step)
            @project.resolve_command(step)
          else
            [step, []]
          end
        when Hash
          if step['command']
            @project.resolve_command(step['command'], normalize_args(step['args']))
          elsif step['run']
            [step['run'], normalize_args(step['args'])]
          else
            raise(Abort, "Up steps must define `command` or `run`: #{step.inspect}")
          end
        else
          raise(Abort, "Unsupported up step: #{step.inspect}")
        end
      end

      def describe_step(step)
        case step
        when String
          if @project.service_config(step)
            "service #{step}"
          elsif @project.command_config(step)
            "dev #{step}"
          else
            step
          end
        when Hash
          step['label'] || (step['service'] ? "service #{step['service']}" : (step['command'] ? "dev #{step['command']}" : step['run']))
        end
      end

      def tracked_name(step, sh = nil, args = [], resolved = nil)
        return resolved.name if resolved&.name

        case step
        when String
          @project.command_config(step) ? step : raw_tracked_name(sh || step, args)
        when Hash
          step['command'] || raw_tracked_name(sh || step['run'], args)
        end
      end

      def raw_tracked_name(sh, args)
        key = ProcessManager.command_string(sh, args)
        occurrence = @raw_command_occurrences[key]
        @raw_command_occurrences[key] += 1
        ProcessManager.raw_command_name(sh, args, occurrence)
      end

      def normalize_args(args)
        Array(args).map(&:to_s)
      end

      def run_shell(sh, args, env = env_builder.command_env)
        ok = system(env, Dev::Shell.bash, '-c', wrap_shell(sh, args), '--', *args)
        raise(AbortSilent) unless ok
      end

      def runtime
        @runtime ||= ServiceRuntime.new(@project, reporter: method(:report_progress))
      end

      def env_builder
        runtime.env_builder
      end

      def start_process(name, sh, args, service_env)
        runtime.start_process(name, sh, args, service_env: service_env)
      end

      def start_managed_service(name, step)
        puts CLI::UI.fmt("{{info:starting}} #{describe_step(step)}")
        runtime.start_managed_service(name)
      end

      def report_progress(message)
        puts CLI::UI.fmt("{{info:...}} #{message}")
      end

      def wrap_shell(sh, _args)
        sh = sh.dup
        sh.concat(' "$@"') if sh.lines.size == 1 && sh !~ /\$[@\*]/
        %Q{runcmd() {\n#{sh}\n}\nruncmd "$@"}
      end
    end
  end
end
