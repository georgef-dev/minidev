require 'dev'

module Dev
  module Commands
    class Reset < Dev::Command
      def call(args, _name)
        all = args.delete('--all')
        raise(Abort, '`dev reset` requires a service name or --all') if args.empty? && !all
        raise(Abort, '`dev reset --all` cannot be combined with service names') if all && !args.empty?

        runtime = ServiceRuntime.new(Project.current)
        targets = all ? runtime.known_service_names : args
        records = runtime.reset(targets)

        if targets.empty? || records.empty?
          puts 'Nothing to reset.'
          return
        end

        targets.each { |target| puts "Reset #{target}." }
      end

      def self.help
        'Reset one service, or all services with --all.'
      end
    end
  end
end
