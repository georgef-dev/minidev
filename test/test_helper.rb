require 'tmpdir'
require 'fileutils'
require 'minitest/autorun'

$LOAD_PATH.unshift(File.expand_path('../vendor/deps/cli-ui/lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('../vendor/deps/cli-kit/lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'dev'

module Minidev
  module TestHelpers
    def with_project(config)
      Dir.mktmpdir('minidev-test') do |dir|
        File.write(File.join(dir, 'dev.yml'), config)
        yield Dev::Project.new(dir)
      end
    end

    def with_home
      previous_home = ENV['HOME']
      Dir.mktmpdir('minidev-home') do |home|
        ENV['HOME'] = home
        yield home
      end
    ensure
      ENV['HOME'] = previous_home
    end
  end
end

class Minitest::Test
  include Minidev::TestHelpers
end
