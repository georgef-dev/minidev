require 'dev'

module Dev
  module Shell
    module_function

    def bash
      path_bash = find_on_path('bash')
      return path_bash if nix_store_path?(path_bash)

      if path_bash
        puts "Warning: PATH bash is not from /nix/store (#{path_bash}); falling back to /bin/bash."
      else
        puts 'Warning: bash was not found on PATH; falling back to /bin/bash.'
      end
      '/bin/bash'
    end

    def find_on_path(name)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    def nix_store_path?(path)
      return false unless path
      return true if path.start_with?('/nix/store/')

      File.realpath(path).start_with?('/nix/store/')
    rescue SystemCallError
      false
    end
  end
end
