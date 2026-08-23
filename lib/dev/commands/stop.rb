require 'dev'

module Dev
  module Commands
    class Stop < Dev::Command
      def call(args, _name)
        project = Project.current
        records = ServiceRuntime.new(project).stop(args)

        if records.empty?
          puts 'No tracked processes to stop.'
        else
          records.each { |record| puts "Stopped #{record.name} (PID #{record.pid})" }
        end
      end

      def self.help
        'Stop tracked project processes. Pass names to stop specific ones.'
      end
    end
  end
end
