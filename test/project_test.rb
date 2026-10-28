require_relative 'test_helper'

class ProjectTest < Minitest::Test
  def test_resolve_command_reads_default_commands
    with_project(<<~YAML) do |project|
      build:
        run: bin/setup
    YAML
      sh, args = project.resolve_command('build')

      assert_equal 'bin/setup', sh
      assert_equal [], args
    end
  end

  def test_resolve_command_reads_custom_commands
    with_project(<<~YAML) do |project|
      commands:
        worker:
          run: bundle exec sidekiq
    YAML
      sh, args = project.resolve_command('worker')

      assert_equal 'bundle exec sidekiq', sh
      assert_equal [], args
    end
  end

  def test_resolve_command_uses_subcommands
    with_project(<<~YAML) do |project|
      commands:
        db:
          subcommands:
            reset:
              run: bin/rails db:reset
    YAML
      sh, args = project.resolve_command('db', ['reset', 'extra'])

      assert_equal 'bin/rails db:reset', sh
      assert_equal ['extra'], args
    end
  end

  def test_resolve_command_raises_for_unknown_command
    with_project("commands: {}\n") do |project|
      error = assert_raises(Dev::Abort) { project.resolve_command('missing') }

      assert_equal 'Unknown command missing', error.message
    end
  end

  def test_services_mysql_config_can_be_read
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: mysql
          database: app_development
          test_database: app_test
          username: app
    YAML

      assert_equal 'mysql', project.service_config('mysql')['type']
      assert_equal 'app_development', project.service_config('mysql')['database']
    end
  end

  def test_invalid_services_shape_fails_directly
    with_project("services: mysql\n") do |project|
      error = assert_raises(Dev::Abort) { project.config }

      assert_equal '`services` must be a map', error.message
    end
  end

  def test_invalid_service_entry_shape_fails_directly
    with_project(<<~YAML) do |project|
      services:
        mysql: true
    YAML
      error = assert_raises(Dev::Abort) { project.config }

      assert_equal 'services.mysql must be a map', error.message
    end
  end

  def test_invalid_service_type_fails_directly
    with_project(<<~YAML) do |project|
      services:
        redis:
          type: redis
    YAML
      error = assert_raises(Dev::Abort) { project.config }

      assert_equal 'services.redis.type must be one of: process, mysql, postgres', error.message
    end
  end

  def test_services_postgres_config_can_be_read
    with_project(<<~YAML) do |project|
      services:
        postgres:
          type: postgres
          database: app_development
          test_database: app_test
          username: app
          password_env: APP_DB_PASSWORD
          env:
            PGOPTIONS: "-c search_path=app"
    YAML

      assert_equal 'postgres', project.service_config('postgres')['type']
      assert_equal 'app_development', project.service_config('postgres')['database']
      assert_equal 'app_test', project.service_config('postgres')['test_database']
      assert_equal 'app', project.service_config('postgres')['username']
      assert_equal 'APP_DB_PASSWORD', project.service_config('postgres')['password_env']
      assert_equal '-c search_path=app', project.service_config('postgres')['env']['PGOPTIONS']
    end
  end

  def test_postgres_service_rejects_unsupported_keys
    with_project(<<~YAML) do |project|
      services:
        postgres:
          type: postgres
          bogus: true
    YAML
      error = assert_raises(Dev::Abort) { project.config }

      assert_equal 'services.postgres has unsupported keys: bogus', error.message
    end
  end

  def test_postgres_service_requires_string_database
    with_project(<<~YAML) do |project|
      services:
        postgres:
          type: postgres
          database: 123
    YAML
      error = assert_raises(Dev::Abort) { project.config }

      assert_equal 'services.postgres.database must be a string', error.message
    end
  end

  def test_mysql_and_postgres_services_cannot_both_be_defined
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: mysql
        postgres:
          type: postgres
    YAML
      error = assert_raises(Dev::Abort) { project.config }

      assert_equal 'dev.yml cannot define both a mysql service and a postgres service; DATABASE_URL would be ambiguous', error.message
    end
  end

  def test_process_service_requires_command_or_run
    with_project(<<~YAML) do |project|
      services:
        worker:
          type: process
    YAML
      error = assert_raises(Dev::Abort) { project.config }

      assert_equal 'services.worker must define exactly one of `command` or `run`', error.message
    end
  end

  def test_collision_warning_prints_to_stdout
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: mysql
      commands:
        mysql:
          run: bin/mysql
    YAML

      out, = capture_io { project.config }

      assert_includes out, 'Warning: services.mysql and commands.mysql both exist'
    end
  end

  def test_readme_managed_mariadb_example_parses_and_resolves_services
    with_project(<<~YAML) do |project|
      env:
        BUNDLE_WITHOUT: production

      services:
        mysql:
          type: mysql
          database: shop_development
          test_database: shop_test
          username: shop
        worker:
          type: process
          command: worker

      up:
        services:
          - mysql
        dependencies:
          - bundle install
          - yarn install
        build:
          - build
        serve:
          - worker

      build: bin/setup
      server: bin/rails server
      test: bin/rails test

      commands:
        worker:
          run: bundle exec sidekiq
    YAML
      resolver = Dev::Services::Resolver.new(project)

      mysql = resolver.resolve_start_step('mysql')
      worker = resolver.resolve_start_step('worker')

      assert_equal :service, mysql.kind
      assert_equal 'mysql', mysql.type
      assert_equal :service, worker.kind
      assert_equal 'bundle exec sidekiq', worker.sh
      assert_equal 'bin/setup', project.resolve_command('build').first
    end
  end

  def test_readme_mysql_migration_keeps_explicit_command_semantics
    with_project(<<~YAML) do |project|
      services:
        mysql:
          type: mysql

      up:
        services:
          - mysql
          - command: mysql

      commands:
        mysql:
          run: bin/docker-db up
    YAML
      resolver = Dev::Services::Resolver.new(project)

      service = resolver.resolve_start_step('mysql')
      command = resolver.resolve_start_step({ 'command' => 'mysql' })

      assert_equal :service, service.kind
      assert_equal 'mysql', service.type
      assert_equal :process, command.kind
      assert_equal 'bin/docker-db up', command.sh
      assert_equal 'bin/docker-db up', project.resolve_command('mysql').first
    end
  end
end
