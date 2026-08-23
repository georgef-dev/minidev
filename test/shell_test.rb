require_relative 'test_helper'

class ShellTest < Minitest::Test
  def test_bash_uses_first_path_bash_when_it_is_under_nix_store
    previous_path = ENV['PATH']
    Dir.mktmpdir('minidev-shell') do |dir|
      nix_dir = File.join(dir, 'nix', 'store', 'abc-bash', 'bin')
      FileUtils.mkdir_p(nix_dir)
      bash = File.join(nix_dir, 'bash')
      File.write(bash, '')
      FileUtils.chmod(0o755, bash)

      Dev::Shell.stub(:find_on_path, '/nix/store/abc-bash/bin/bash') do
        out, = capture_io { assert_equal '/nix/store/abc-bash/bin/bash', Dev::Shell.bash }
        assert_empty out
      end
    ensure
      ENV['PATH'] = previous_path
    end
  end

  def test_bash_warns_and_falls_back_when_path_bash_is_not_nix
    Dev::Shell.stub(:find_on_path, '/usr/bin/bash') do
      out, = capture_io { assert_equal '/bin/bash', Dev::Shell.bash }
      assert_includes out, 'Warning: PATH bash is not from /nix/store'
    end
  end

  def test_bash_accepts_profile_symlink_to_nix_store
    Dev::Shell.stub(:find_on_path, '/profile/bin/bash') do
      File.stub(:realpath, '/nix/store/abc-bash/bin/bash') do
        out, = capture_io { assert_equal '/profile/bin/bash', Dev::Shell.bash }

        assert_empty out
      end
    end
  end

  def test_bash_warns_and_falls_back_when_missing
    Dev::Shell.stub(:find_on_path, nil) do
      out, = capture_io { assert_equal '/bin/bash', Dev::Shell.bash }
      assert_includes out, 'Warning: bash was not found on PATH'
    end
  end
end
