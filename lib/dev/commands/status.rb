require 'dev'

module Dev
  module Commands
    class Status < Dev::Command
      def call(args, _name)
        raise(Abort, '`dev status` does not take any arguments') unless args.empty?

        project = Project.current
        runtime = ServiceRuntime.new(project)
        services = runtime.services
        print_header(runtime)

        if services.empty?
          puts 'No services have been started for this instance.'
          puts 'Run `dev up` to start configured services.'
          return
        end

        puts format('%-16s %-8s %-8s %-9s %-8s %-8s %-s', 'SERVICE', 'TYPE', 'STATE', 'READY', 'PID', 'PORT', 'LOG')
        services.each do |service|
          puts format('%-16s %-8s %-8s %-9s %-8s %-8s %-s', service['name'], service['type'], service['state'], service['ready'], service['pid'] || '-', service['port'] || '-', relative(runtime, service['log_path']))
        end
      end

      def self.help
        'Show service status for the current instance.'
      end

      private

      def print_header(runtime)
        puts "Instance: #{runtime.instance.label}"
        puts "Project:  #{runtime.instance.project_root}"
        puts "State:    #{runtime.instance.state_root}"
        puts ''
      end

      def relative(runtime, path)
        return '-' unless path

        path.start_with?(runtime.instance.state_root + File::SEPARATOR) ? path.delete_prefix(runtime.instance.state_root + File::SEPARATOR) : path
      end
    end
  end
end
