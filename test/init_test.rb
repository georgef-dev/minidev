require_relative 'test_helper'

class InitTest < Minitest::Test
  def test_init_writes_boilerplate_dev_yml
    Dir.mktmpdir('minidev-init') do |dir|
      Dir.chdir(dir) do
        out, = capture_io { Dev::Commands::Init.call([], 'init') }

        assert_equal "Created dev.yml\n", out
        assert File.exist?('dev.yml')
        project = Dev::Project.new(dir)
        assert_equal 'bin/setup', project.resolve_command('build').first
        assert_equal 'bin/rails server', project.resolve_command('server').first
        assert_equal 'bin/rails test', project.resolve_command('test').first
      end
    end
  end

  def test_init_refuses_to_overwrite_existing_dev_yml
    Dir.mktmpdir('minidev-init') do |dir|
      Dir.chdir(dir) do
        File.write('dev.yml', "test: existing\n")

        error = assert_raises(Dev::Abort) { Dev::Commands::Init.call([], 'init') }

        assert_equal 'dev.yml already exists', error.message
        assert_equal "test: existing\n", File.read('dev.yml')
      end
    end
  end

  def test_init_rejects_arguments
    Dir.mktmpdir('minidev-init') do |dir|
      Dir.chdir(dir) do
        error = assert_raises(Dev::Abort) { Dev::Commands::Init.call(['--force'], 'init') }

        assert_equal '`dev init` does not take any arguments', error.message
        refute File.exist?('dev.yml')
      end
    end
  end
end
