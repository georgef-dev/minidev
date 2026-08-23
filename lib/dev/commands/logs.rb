require 'dev'

module Dev
  module Commands
    class Logs < Dev::Command
      def call(args, _name)
        raise(Abort, '`dev logs` takes at most one service name') if args.size > 1

        project = Project.current
        runtime = ServiceRuntime.new(project)
        args.empty? ? list_logs(runtime) : print_log(runtime, args.first)
      end

      def self.help
        'List service logs or print one service log.'
      end

      private

      def list_logs(runtime)
        services = runtime.services
        puts "Instance: #{runtime.instance.label}"
        puts ''
        if services.empty?
          puts 'No service logs are known for this instance.'
          return
        end

        puts format('%-16s %-8s %-s', 'SERVICE', 'STATE', 'LOG')
        services.each do |service|
          puts format('%-16s %-8s %-s', service['name'], service['state'], relative(runtime, service['log_path']))
        end
        puts ''
        puts 'Run `dev logs <service>` to print a service log.'
      end

      def print_log(runtime, name)
        service = runtime.service(name)
        unknown_service(runtime, name) unless service
        log_path = service['log_path']
        unless log_path
          unless service['record']
            puts "No log file exists for #{name} yet."
            puts 'Run `dev up` to start the service.'
            return
          end

          puts "Service #{name} has partial state: missing log path."
          puts "Run `dev status` to refresh state, or `dev reset #{name}` if the service cannot recover."
          return
        end

        unless File.exist?(log_path)
          puts "No log file exists for #{name} yet."
          puts 'Run `dev up` to start the service.'
          return
        end

        puts "Log: #{log_path}"
        puts ''
        puts File.read(log_path)
      end

      def unknown_service(runtime, name)
        known = runtime.known_service_names
        message = "Unknown service: #{name}"
        message += "\nKnown services: #{known.join(', ')}" unless known.empty?
        raise(Abort, message)
      end

      def relative(runtime, path)
        return '-' unless path

        path.start_with?(runtime.instance.state_root + File::SEPARATOR) ? path.delete_prefix(runtime.instance.state_root + File::SEPARATOR) : path
      end
    end
  end
end
