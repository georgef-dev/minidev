require_relative 'test_helper'
require 'json'

class InstanceTest < Minitest::Test
  def test_instance_id_is_deterministic_for_same_identity
    with_home do
      with_project("test: ruby -v\n") do |project|
        first = Dev::Instance.for_project(project)
        second = Dev::Instance.for_project(project)

        assert_equal first.instance_id, second.instance_id
        assert_match(/\Av1-[0-9a-f]{64}\z/, first.instance_id)
        assert_equal 'development', first.environment
      end
    end
  end

  def test_different_project_roots_produce_different_ids
    with_home do
      with_project("test: ruby -v\n") do |first_project|
        with_project("test: ruby -v\n") do |second_project|
          first = Dev::Instance.for_project(first_project)
          second = Dev::Instance.for_project(second_project)

          refute_equal first.instance_id, second.instance_id
        end
      end
    end
  end

  def test_different_worktree_roots_produce_different_ids
    with_home do
      Dir.mktmpdir('minidev-instance') do |project_root|
        File.write(File.join(project_root, 'dev.yml'), "test: ruby -v\n")

        first = Dev::Instance.new(project_root: project_root, worktree_root: project_root)
        Dir.mktmpdir('minidev-worktree') do |worktree_root|
          second = Dev::Instance.new(project_root: project_root, worktree_root: worktree_root)

          refute_equal first.instance_id, second.instance_id
        end
      end
    end
  end

  def test_resolves_git_worktree_root_for_subproject
    skip 'git is required' unless system('git', '--version', out: File::NULL, err: File::NULL)

    with_home do
      Dir.mktmpdir('minidev-git') do |worktree_root|
        system('git', 'init', '-q', worktree_root, out: File::NULL, err: File::NULL)
        project_root = File.join(worktree_root, 'apps', 'web')
        FileUtils.mkdir_p(project_root)
        File.write(File.join(project_root, 'dev.yml'), "test: ruby -v\n")

        instance = Dev::Instance.new(project_root: project_root)

        assert_equal File.realpath(worktree_root), instance.worktree_root
        assert_equal File.realpath(project_root), instance.project_root
      end
    end
  end

  def test_state_paths_are_under_home_state_root
    with_home do |home|
      with_project("test: ruby -v\n") do |project|
        instance = Dev::Instance.for_project(project)

        assert_equal File.join(home, '.local', 'state', 'minidev', 'instances', instance.instance_id), instance.state_root
        assert_equal File.join(instance.state_root, 'logs'), instance.paths['logs_dir']
        assert_equal File.join(instance.state_root, 'pids'), instance.paths['pids_dir']
      end
    end
  end

  def test_slugged_worktree_name_is_stable_and_filename_safe
    with_home do
      Dir.mktmpdir('minidev-parent') do |parent|
        worktree_root = File.join(parent, 'My Worktree!!')
        project_root = File.join(worktree_root, 'app')
        FileUtils.mkdir_p(project_root)
        File.write(File.join(project_root, 'dev.yml'), "test: ruby -v\n")

        instance = Dev::Instance.new(project_root: project_root, worktree_root: worktree_root)

        assert_equal 'my-worktree', instance.slugged_worktree_name
      end
    end
  end
end
