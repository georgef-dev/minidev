require 'dev'

module Dev
  module Commands
    class Contextual < Dev::Command
      def call(args, name)
        project = Project.current
        sh, args = project.resolve_command(name, args)
        runtime = ServiceRuntime.new(project)

        runtime.refresh
        puts("\x1b[1;34mexecuting #{sh}\x1b[0m")

        sh.concat(' "$@"') if sh.lines.size == 1 && sh !~ /\$[@\*]/
        sh = %Q{runcmd() {\n#{sh}\n}\nruncmd "$@"}
        exec(runtime.env_builder.command_env, Dev::Shell.bash, '-c', sh, '--', *args)
      end

      def self.help
        'Run a project command from dev.yml in the foreground.'
      end
    end
  end
end
