require 'dev'

module Dev
  module Commands
    class Env < Dev::Command
      SECRET_KEY = /(PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY)/i

      def call(args, _name)
        raise(Abort, '`dev env` does not take any arguments') unless args.empty?

        ServiceRuntime.new(Project.current).controlled_env.each do |key, value|
          puts "#{key}=#{redact(key, value)}"
        end
      end

      def self.help
        'Print minidev-controlled environment values.'
      end

      private

      def redact(key, value)
        key.match?(SECRET_KEY) ? '<redacted>' : value
      end
    end
  end
end
