require 'dev'

module Dev
  module Commands
    class Ps < Dev::Command
      def call(args, _name)
        raise(Abort, '`dev ps` does not take any arguments') unless args.empty?

        project = Project.current
        records = ServiceRuntime.new(project).ps

        if records.empty?
          puts 'No tracked processes are running.'
          return
        end

        puts format('%-12s %-8s %-s', 'NAME', 'PID', 'COMMAND')
        records.each do |record|
          puts format('%-12s %-8s %-s', record.name, record.pid, record.command)
        end
      end

      def self.help
        'List tracked project processes.'
      end
    end
  end
end
