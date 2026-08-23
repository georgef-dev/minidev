require 'dev'

module Dev
  module Commands
    class Doctor < Dev::Command
      def call(args, _name)
        raise(Abort, '`dev doctor` does not take any arguments') unless args.empty?

        report = Dev::Doctor.new.call
        report.each { |finding| puts(format_finding(finding)) }
        raise(Abort, 'dev doctor found errors') if report.any? { |finding| finding.status == :error }
      end

      def self.help
        'Inspect the active project environment without starting services or running project commands.'
      end

      private

      def format_finding(finding)
        detail = finding.detail ? " - #{finding.detail}" : ''
        "#{finding.status.to_s.upcase}: #{finding.message}#{detail}"
      end
    end
  end
end
