require 'dev'

module Dev
  module Services
    class Resolver
      Resolved = Struct.new(:kind, :name, :type, :sh, :args, :label, :env, keyword_init: true)

      def initialize(project)
        @project = project
      end

      def resolve_start_step(step)
        case step
        when String
          if @project.service_config(step)
            resolve_service(step)
          else
            resolve_command_or_raw(step)
          end
        when Hash
          if step['service']
            resolve_service(step['service'].to_s)
          elsif step['command']
            sh, args = @project.resolve_command(step['command'], normalize_args(step['args']))
            Resolved.new(kind: :process, name: step['command'], type: 'process', sh: sh, args: args, label: step['label'], env: {})
          elsif step['run']
            Resolved.new(kind: :process, name: nil, type: 'process', sh: step['run'], args: normalize_args(step['args']), label: step['label'], env: {})
          else
            raise(Abort, "Up service steps must define `service`, `command`, or `run`: #{step.inspect}")
          end
        else
          raise(Abort, "Unsupported up service step: #{step.inspect}")
        end
      end

      private

      def resolve_service(name)
        cfg = @project.service_config(name)
        raise(Abort, "Unknown service #{name}") unless cfg

        case cfg['type']
        when 'process'
          sh, args = resolve_process_command(name, cfg)
          Resolved.new(kind: :service, name: name, type: 'process', sh: sh, args: args, label: cfg['label'], env: cfg.fetch('env', {}))
        when 'mysql'
          Resolved.new(kind: :service, name: name, type: 'mysql', label: name, env: cfg.fetch('env', {}))
        when 'postgres'
          Resolved.new(kind: :service, name: name, type: 'postgres', label: name, env: cfg.fetch('env', {}))
        else
          raise(Abort, "Unsupported service type #{cfg['type']} for #{name}")
        end
      end

      def resolve_process_command(name, cfg)
        args = normalize_args(cfg['args'])
        if cfg['command']
          @project.resolve_command(cfg['command'], args)
        elsif cfg['run']
          [cfg['run'], args]
        else
          raise(Abort, "services.#{name} must define exactly one of `command` or `run`")
        end
      end

      def resolve_command_or_raw(step)
        if @project.command_config(step)
          sh, args = @project.resolve_command(step)
          Resolved.new(kind: :process, name: step, type: 'process', sh: sh, args: args, label: nil, env: {})
        else
          Resolved.new(kind: :process, name: nil, type: 'process', sh: step, args: [], label: nil, env: {})
        end
      end

      def normalize_args(args)
        Array(args).map(&:to_s)
      end
    end
  end
end
