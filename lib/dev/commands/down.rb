require 'dev'

module Dev
  module Commands
    class Down < Dev::Command
      def call(args, _name)
        raise(Abort, '`dev down` does not take any arguments') unless args.empty?

        project = Project.current
        runtime = ServiceRuntime.new(project)
        records = runtime.stop
        records.each { |record| puts "Stopped #{record.name} (PID #{record.pid})" }
        runtime.cleanup!
        puts 'Cleaned up tracked process state.'
      end

      def self.help
        'Stop all tracked project processes and remove .dev state.'
      end
    end
  end
end
