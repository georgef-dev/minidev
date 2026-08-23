require 'dev'

module Dev
  module Commands
    class Init < Dev::Command
      BOILERPLATE = <<~YAML
        up:
          build:
            - build
          serve:
            - server

        build: bin/setup
        server: bin/rails server
        test: bin/rails test
      YAML

      def call(args, _name)
        raise(Abort, '`dev init` does not take any arguments') unless args.empty?

        path = File.join(Dir.pwd, 'dev.yml')
        raise(Abort, 'dev.yml already exists') if File.exist?(path)

        File.write(path, BOILERPLATE)
        puts 'Created dev.yml'
      end

      def self.help
        'Create a boilerplate dev.yml in the current directory.'
      end
    end
  end
end
