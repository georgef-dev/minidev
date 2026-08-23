require_relative 'test_helper'

class UpTest < Minitest::Test
  def setup
    @up = Dev::Commands::Up.new
  end

  def test_normalize_up_hash_collects_services_setup_steps_and_serve_step
    instructions, service_steps, setup_steps, serve_steps = @up.send(:normalize_up, {
      'instructions' => ['Install Redis'],
      'services' => ['mysql'],
      'dependencies' => ['bundle install'],
      'build' => ['build'],
      'steps' => [{ 'run' => 'bin/rails db:prepare' }],
      'serve' => 'server',
    })

    assert_equal ['Install Redis'], instructions
    assert_equal ['mysql'], service_steps
    assert_equal ['bundle install', 'build', { 'run' => 'bin/rails db:prepare' }], setup_steps
    assert_equal ['server'], serve_steps
  end

  def test_normalize_up_array_uses_last_step_as_serve
    instructions, service_steps, setup_steps, serve_steps = @up.send(:normalize_up, ['bundle install', 'server'])

    assert_equal [], instructions
    assert_equal [], service_steps
    assert_equal ['bundle install'], setup_steps
    assert_equal ['server'], serve_steps
  end

  def test_resolve_step_uses_project_commands_when_available
    with_project(<<~YAML) do |project|
      build: bin/setup
    YAML
      @up.instance_variable_set(:@project, project)

      sh, args = @up.send(:resolve_step, 'build')

      assert_equal 'bin/setup', sh
      assert_equal [], args
    end
  end

  def test_resolve_step_keeps_raw_shell_strings
    with_project("commands: {}\n") do |project|
      @up.instance_variable_set(:@project, project)

      sh, args = @up.send(:resolve_step, 'bundle install')

      assert_equal 'bundle install', sh
      assert_equal [], args
    end
  end

  def test_up_services_string_resolves_service_before_command
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: process
          run: bin/service-mysql
      commands:
        mysql:
          run: bin/command-mysql
    YAML
      resolver = Dev::Services::Resolver.new(project)

      resolved = resolver.resolve_start_step('mysql')

      assert_equal :service, resolved.kind
      assert_equal 'mysql', resolved.name
      assert_equal 'bin/service-mysql', resolved.sh
    end
  end

  def test_command_only_up_services_string_still_resolves_command
    with_project(<<~YAML) do |project|
      commands:
        mysql:
          run: bin/command-mysql
    YAML
      resolver = Dev::Services::Resolver.new(project)

      resolved = resolver.resolve_start_step('mysql')

      assert_equal :process, resolved.kind
      assert_equal 'mysql', resolved.name
      assert_equal 'bin/command-mysql', resolved.sh
    end
  end

  def test_explicit_service_resolves_only_services
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: mysql
    YAML
      resolver = Dev::Services::Resolver.new(project)

      resolved = resolver.resolve_start_step({ 'service' => 'mysql' })

      assert_equal :service, resolved.kind
      assert_equal 'mysql', resolved.name
      assert_equal 'mysql', resolved.type
    end
  end

  def test_explicit_service_errors_when_missing
    with_project(<<~YAML) do |project|
      commands:
        mysql:
          run: bin/command-mysql
    YAML
      resolver = Dev::Services::Resolver.new(project)

      error = assert_raises(Dev::Abort) { resolver.resolve_start_step({ 'service' => 'mysql' }) }

      assert_equal 'Unknown service mysql', error.message
    end
  end

  def test_explicit_command_resolves_command_even_with_same_named_service
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: mysql
      commands:
        mysql:
          run: bin/command-mysql
    YAML
      resolver = Dev::Services::Resolver.new(project)

      resolved = resolver.resolve_start_step({ 'command' => 'mysql' })

      assert_equal :process, resolved.kind
      assert_equal 'mysql', resolved.name
      assert_equal 'bin/command-mysql', resolved.sh
    end
  end

  def test_call_starts_tracked_services_before_setup_and_skips_serve
    with_project(<<~YAML) do |project|
      up:
        instructions:
          - Install Redis
        services:
          - mysql
        dependencies:
          - bundle install
        build:
          - build
        steps:
          - run: bin/rails db:prepare
        serve: server
      build: bin/setup
      server: bin/rails server
      commands:
        mysql:
          run: bin/mysql
    YAML
      Dev::Project.stub(:current, project) do
        events = []
        runtime = Object.new
        runtime.define_singleton_method(:refresh) {}

        @up.stub(:puts, nil) do
          @up.stub(:run_shell, ->(sh, args) { events << [:run, sh, args] }) do
            @up.stub(:runtime, runtime) do
              @up.stub(:start_process, ->(name, sh, args, _env) { events << [:start, name, sh, args] }) do
                @up.call([], 'up')
              end
            end
          end
        end

        assert_equal [
          [:start, 'mysql', 'bin/mysql', []],
          [:run, 'bundle install', []],
          [:run, 'bin/setup', []],
          [:run, 'bin/rails db:prepare', []],
        ], events
      end
    end
  end

  def test_call_prints_runtime_refresh_progress
    with_project(<<~YAML) do |project|
      up:
        serve: server
      server: bin/rails server
    YAML
      Dev::Project.stub(:current, project) do
        runtime = Object.new
        runtime.define_singleton_method(:refresh) {}

        @up.stub(:runtime, runtime) do
          @up.stub(:start_process, ->(_name, _sh, _args, _env) {}) do
            out, = capture_io { @up.call([], 'up') }

            assert_includes out, 'checking current service state'
            assert_includes out, 'checked current service state'
          end
        end
      end
    end
  end

  def test_call_starts_multiple_service_entries_with_stable_names_and_skips_serve
    with_project(<<~YAML) do |project|
      up:
        services:
          - mysql
          - run: redis-server
        serve:
          - server
          - command: worker
          - run: redis-server
      server: bin/rails server
      commands:
        mysql:
          run: bin/mysql
        worker:
          run: bundle exec sidekiq
    YAML
      Dev::Project.stub(:current, project) do
        starts = []
        runtime = Object.new
        runtime.define_singleton_method(:refresh) {}

        @up.stub(:puts, nil) do
          @up.stub(:runtime, runtime) do
            @up.stub(:start_process, ->(name, sh, args, _env) { starts << [name, sh, args] }) do
              @up.call([], 'up')
            end
          end
        end

        assert_equal [
          ['mysql', 'bin/mysql', []],
          [Dev::ProcessManager.raw_command_name('redis-server', [], 0), 'redis-server', []],
        ], starts
      end
    end
  end

  def test_call_does_not_start_process_services_from_up_serve
    with_project(<<~YAML) do |project|
      up:
        serve:
          - worker
      services:
        worker:
          type: process
          command: worker
      commands:
        worker:
          run: bundle exec sidekiq
    YAML
      Dev::Project.stub(:current, project) do
        starts = []
        runtime = Object.new
        runtime.define_singleton_method(:refresh) {}

        @up.stub(:puts, nil) do
          @up.stub(:runtime, runtime) do
            @up.stub(:start_process, ->(name, sh, args, _env) { starts << [name, sh, args] }) do
              @up.call([], 'up')
            end
          end
        end

        assert_equal [], starts
      end
    end
  end

  def test_call_starts_mysql_service_through_runtime
    with_project(<<~YAML) do |project|
      up:
        services:
          - mysql
      services:
        mysql:
          type: mysql
    YAML
      Dev::Project.stub(:current, project) do
        runtime = Object.new
        runtime.define_singleton_method(:refresh) {}

        @up.stub(:puts, nil) do
          @up.stub(:runtime, runtime) do
            started = []
            runtime.define_singleton_method(:start_mysql) { |name| started << name }
            @up.call([], 'up')

            assert_equal ['mysql'], started
          end
        end
      end
    end
  end

  def test_setup_steps_use_env_builder_env
    with_home do
      Dir.mktmpdir('minidev-up') do |dir|
        output = File.join(dir, 'env.txt')
        File.write(File.join(dir, 'dev.yml'), <<~YAML)
          up:
            dependencies:
              - run: ruby -e 'File.write(ARGV[0], ENV.fetch("MINIDEV_INSTANCE_ID") + ":" + ENV.fetch("PROJECT_ENV"))'
                args: [#{output}]
          env:
            PROJECT_ENV: configured
        YAML
        project = Dev::Project.new(dir)

        Dev::Project.stub(:current, project) do
          @up.stub(:puts, nil) do
            Dev::Shell.stub(:bash, '/bin/bash') do
              @up.call([], 'up')
            end
          end
        end

        instance = Dev::Instance.for_project(project)
        assert_equal "#{instance.instance_id}:configured", File.read(output)
      end
    end
  end

  def test_process_service_env_is_included_for_service_start
    with_home do
      Dir.mktmpdir('minidev-up') do |dir|
        output = File.join(dir, 'worker-env.txt')
        File.write(File.join(dir, 'dev.yml'), <<~YAML)
          up:
            services:
              - worker
          services:
            worker:
              type: process
              run: ruby -e 'File.write(ARGV[0], ENV.fetch("WORKER_ENV")); sleep 5'
              args: [#{output}]
              env:
                WORKER_ENV: service-value
        YAML
        project = Dev::Project.new(dir)
        runtime = Dev::ServiceRuntime.new(project)

        Dev::Project.stub(:current, project) do
          @up.stub(:puts, nil) do
            Dev::Shell.stub(:bash, '/bin/bash') do
              @up.call([], 'up')
            end
          end
        end

        deadline = Time.now + 2
        sleep 0.05 until File.exist?(output) || Time.now > deadline
        assert_equal 'service-value', File.read(output)
      ensure
        runtime&.stop
      end
    end
  end

  def test_call_suffixes_duplicate_raw_tracked_command_occurrences
    with_project(<<~YAML) do |project|
      up:
        services:
          - redis-server
          - run: redis-server
        serve:
          - run: redis-server
            args: [--port, '6380']
          - run: redis-server
            args: [--port, '6380']
      commands: {}
    YAML
      Dev::Project.stub(:current, project) do
        starts = []
        runtime = Object.new
        runtime.define_singleton_method(:refresh) {}

        @up.stub(:puts, nil) do
          @up.stub(:runtime, runtime) do
            @up.stub(:start_process, ->(name, sh, args, _env) { starts << [name, sh, args] }) do
              @up.call([], 'up')
            end
          end
        end

        assert_equal [
          [Dev::ProcessManager.raw_command_name('redis-server', [], 0), 'redis-server', []],
          [Dev::ProcessManager.raw_command_name('redis-server', [], 1), 'redis-server', []],
        ], starts
      end
    end
  end

  def test_call_aborts_when_setup_step_fails
    with_project(<<~YAML) do |project|
      up:
        dependencies:
          - bundle install
        serve: server
      server: bin/rails server
    YAML
      Dev::Project.stub(:current, project) do
        runtime = Object.new
        runtime.define_singleton_method(:refresh) {}

        @up.stub(:puts, nil) do
          @up.stub(:runtime, runtime) do
            @up.stub(:run_shell, ->(_sh, _args) { raise Dev::AbortSilent }) do
              assert_raises(Dev::AbortSilent) { @up.call([], 'up') }
            end
          end
        end
      end
    end
  end

  def test_old_hash_configs_without_services_do_not_start_serve
    with_project(<<~YAML) do |project|
      up:
        dependencies:
          - bundle install
        serve: server
      server: bin/rails server
    YAML
      Dev::Project.stub(:current, project) do
        starts = []
        runtime = Object.new
        runtime.define_singleton_method(:refresh) {}

        @up.stub(:puts, nil) do
          @up.stub(:run_shell, ->(_sh, _args) {}) do
            @up.stub(:runtime, runtime) do
              @up.stub(:start_process, ->(name, sh, args, _env) { starts << [name, sh, args] }) do
                @up.call([], 'up')
              end
            end
          end
        end

        assert_equal [], starts
      end
    end
  end
end
