require 'dev'

module Dev
  module Commands
    class Help < Dev::Command
      def call(args, _name)
        raise(Abort, '`dev help` does not take any arguments') unless args.empty?

        puts CLI::UI.fmt("{{bold:minidev}}")
        puts ""
        print_project_commands
        print_section('Services', [
          ['up', 'Run setup and start configured services'],
          ['down', 'Stop all tracked processes'],
          ['ps', 'List running tracked processes'],
          ['stop [name]', 'Stop tracked process(es)'],
          ['status', 'Show service status'],
          ['logs [name]', 'List or print service logs'],
          ['env', 'Print minidev-controlled env'],
          ['reset <name>', 'Reset one service'],
          ['reset --all', 'Reset all services'],
        ])
        print_section('Project setup', [
          ['init', 'Create a boilerplate dev.yml'],
          ['doctor', 'Inspect project environment'],
        ])
        print_section('Navigation', [
          ['cd <repo>', 'Jump to repo under github_root'],
          ['clone <repo>', 'Clone repo under github_root'],
          ['open pr', 'Open PR page for current branch'],
        ])
        print_section('Config', [
          ['config', 'Print config'],
          ['config get default.github_root', 'Print one config value'],
          ['config set default.github_root <path>', 'Set one config value'],
          ['config unset default.github_root', 'Unset one config value'],
        ], trailing_blank: false)
      end

      private

      def print_project_commands
        commands = Dev::ContextualResolver.command_names
        return if commands.empty?

        rows = commands.map { |name| [name, project_command_description(name)] }
        print_section('Project commands', rows)
      end

      def project_command_description(name)
        case name
        when 'server'
          'Run project server command'
        when 'test'
          'Run project test command'
        when 'build'
          'Run project build command'
        when 'console'
          'Run project console command'
        when 'style'
          'Run project style command'
        else
          'Run custom project command'
        end
      end

      def print_section(title, rows, trailing_blank: true)
        puts CLI::UI.fmt("{{bold:#{title}}}")
        rows.each do |command, description|
          puts format('  %-39s %s', CLI::UI.fmt("{{command:#{Dev::TOOL_NAME} #{command}}}"), description)
        end
        puts '' if trailing_blank
      end
    end
  end
end
