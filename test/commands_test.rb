require_relative 'test_helper'
require 'stringio'

class CommandsTest < Minitest::Test
  def test_implemented_command_help_is_not_placeholder_text
    command_classes = [
      Dev::Commands::Cd,
      Dev::Commands::Clone,
      Dev::Commands::Config,
      Dev::Commands::Contextual,
      Dev::Commands::Init,
      Dev::Commands::Open,
    ]

    command_classes.each do |command_class|
      refute_equal 'TODO', command_class.help
      refute_empty command_class.help
    end
  end

  def test_contextual_command_names_ignore_top_level_services
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: mysql
      commands:
        worker:
          run: bundle exec sidekiq
    YAML

      Dev::Project.stub(:current, project) do
        assert_equal ['worker'], Dev::ContextualResolver.command_names
      end
    end
  end

  def test_help_lists_project_defined_contextual_commands
    with_project(<<~YAML) do |project|
      test: bin/test
      server: bin/rails server
      build: bin/setup
      services:
        mysql:
          type: mysql
      commands:
        worker:
          run: bundle exec sidekiq
    YAML
      Dev::Project.stub(:current, project) do
        out, = capture_io { Dev::Commands::Help.call([], 'help') }

        assert_includes out, 'minidev'
        assert_includes out, 'Project commands'
        assert_includes out, 'Services'
        assert_includes out, 'Project setup'
        assert_includes out, 'Navigation'
        assert_includes out, 'Config'
        assert_includes out, 'dev test'
        assert_includes out, 'dev server'
        assert_includes out, 'dev build'
        assert_includes out, 'dev worker'
        assert_includes out, 'Run project test command'
        assert_includes out, 'Run project server command'
        assert_includes out, 'Run custom project command'
        assert_includes out, 'dev reset --all'
        assert_includes out, 'dev config set default.github_root <path>'
        refute_includes out, 'dev mysql'
        refute_includes out, 'Run a project command from dev.yml in the foreground.'
      end
    end
  end

  def test_help_without_project_omits_project_commands_section
    Dir.mktmpdir('minidev-no-project') do |dir|
      Dir.chdir(dir) do
        out, = capture_io { Dev::Commands::Help.call([], 'help') }

        refute_includes out, 'Project commands'
        assert_includes out, 'Services'
        assert_includes out, 'dev up'
      end
    end
  end

  def test_cd_candidates_include_standardized_monorepo_apps
    Dir.mktmpdir('minidev-github-root') do |root|
      repo = File.join(root, 'georgef-dev', 'relay')
      FileUtils.mkdir_p(File.join(repo, 'areas', 'clients', 'admin-web'))
      FileUtils.mkdir_p(File.join(repo, 'areas', 'core', 'relay'))
      FileUtils.mkdir_p(File.join(repo, 'areas', 'work', 'ignored'))
      FileUtils.mkdir_p(File.join(repo, 'areas', 'clients', 'admin-web', 'nested-app'))

      with_github_root(root) do
        candidates = Dev::Commands::Cd.new.avail

        assert_includes candidates, 'georgef-dev/relay'
        assert_includes candidates, 'georgef-dev/relay/areas/clients/admin-web'
        assert_includes candidates, 'georgef-dev/relay/areas/core/relay'
        refute_includes candidates, 'georgef-dev/relay/areas/work/ignored'
        refute_includes candidates, 'georgef-dev/relay/areas/clients/admin-web/nested-app'
      end
    end
  end

  def test_cd_can_select_standardized_monorepo_app
    Dir.mktmpdir('minidev-github-root') do |root|
      target = File.join(root, 'georgef-dev', 'relay', 'areas', 'clients', 'admin-web')
      FileUtils.mkdir_p(target)

      with_github_root(root) do
        command = Dev::Commands::Cd.new
        command.stub(:avail, ['georgef-dev/relay', 'georgef-dev/relay/areas/clients/admin-web']) do
          CLI::Kit::System.stub(:capture2, ["georgef-dev/relay/areas/clients/admin-web\n", success_status]) do
            io = StringIO.new
            IO.stub(:new, io) do
              command.call(['admin-web'], 'cd')
            end

            assert_equal "chdir:#{target}\n", io.string
          end
        end
      end
    end
  end

  def test_contextual_exec_commands_use_env_builder_env
    %w(test console server worker).each do |name|
      with_home do
        with_project(<<~YAML) do |project|
          env:
            PROJECT_ENV: configured
          test: ruby test.rb
          console: ruby console.rb
          server: ruby server.rb
          commands:
            worker:
              run: ruby worker.rb
        YAML
          command = Dev::Commands::Contextual.new
          captured = nil

          Dev::Project.stub(:current, project) do
            Dev::Shell.stub(:bash, '/bin/bash') do
              command.stub(:exec, ->(*argv) { captured = argv }) do
                command.stub(:puts, nil) do
                  command.call([], name)
                end
              end
            end
          end

          env = captured.first
          assert_equal 'configured', env['PROJECT_ENV']
          assert_equal Dev::Instance.for_project(project).instance_id, env['MINIDEV_INSTANCE_ID']
          assert_equal ['/bin/bash', '-c'], captured[1..2]
        end
      end
    end
  end

  def test_stop_command_stops_named_process
    with_home do
      with_project("server: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        manager.start('server', 'sleep 5', [])

        Dev::Project.stub(:current, project) do
          Dev::Commands::Stop.new.stub(:puts, nil) do
            Dev::Commands::Stop.call(['server'], 'stop')
          end
        end

        assert_equal [], manager.ps
        manager.cleanup!
      end
    end
  end

  def test_stop_command_stops_tracked_dependency_service
    with_home do
      with_project("commands:\n  mysql:\n    run: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        manager.start('mysql', 'sleep 5', [])

        Dev::Project.stub(:current, project) do
          Dev::Commands::Stop.new.stub(:puts, nil) do
            Dev::Commands::Stop.call(['mysql'], 'stop')
          end
        end

        assert_equal [], manager.ps
        manager.cleanup!
      end
    end
  end

  def test_down_command_stops_processes_and_cleans_state
    with_home do
      with_project("server: sleep 5\n") do |project|
        manager = Dev::ProcessManager.new(project)
        instance = Dev::Instance.for_project(project)
        manager.start('server', 'sleep 5', [])

        Dev::Project.stub(:current, project) do
          Dev::Commands::Down.new.stub(:puts, nil) do
            Dev::Commands::Down.call([], 'down')
          end
        end

        assert Dir.exist?(instance.state_root)
        assert_equal [], manager.ps
      end
    end
  end

  private

  def with_github_root(root)
    had_previous = Dev::Default.class_variable_defined?(:@@github_root)
    previous = Dev::Default.class_variable_get(:@@github_root) if had_previous
    Dev::Default.class_variable_set(:@@github_root, root)
    yield
  ensure
    Dev::Default.remove_class_variable(:@@github_root) if Dev::Default.class_variable_defined?(:@@github_root)
    Dev::Default.class_variable_set(:@@github_root, previous) if had_previous
  end

  def success_status
    status = Object.new
    status.define_singleton_method(:success?) { true }
    status
  end
end
