require 'dev'

module Dev
  module Commands
    FZY = begin
      basename = RUBY_PLATFORM =~ /darwin/ ? 'fzy_darwin' : 'fzy_linux'
      File.expand_path("vendor/#{basename}", ROOT)
    end

    class Cd < Dev::Command
      def call(args, _name)
        raise(Abort, 'one arg required') unless args.size == 1
        arg = args.first
        scores, stat = CLI::Kit::System.capture2(FZY, '--show-matches', arg, stdin_data: avail.join("\n"))
        raise(Abort, 'fzy failed') unless stat.success?
        raise(Abort, "no such file or directory: #{arg}") if scores.empty?

        target = File.expand_path(File.join(Dev::Default.github_root, scores.lines.first))
        IO.new(9).puts("chdir:#{target}")
      end

      def avail
        owners.flat_map do |owner|
          repos_for(owner).flat_map { |repo| repo_candidates(owner, repo) }
        end
      end

      def self.help
        'Find a repository or standardized monorepo app under the configured github_root and change into it.'
      end

      private

      def github_root
        File.expand_path(Dev::Default.github_root)
      end

      def owners
        directories(github_root)
      end

      def repos_for(owner)
        directories(File.join(github_root, owner))
      end

      def repo_candidates(owner, repo)
        root_candidate = File.join(owner, repo)
        [root_candidate] + monorepo_area_candidates(root_candidate)
      end

      def monorepo_area_candidates(root_candidate)
        %w(clients core).flat_map do |area|
          area_root = File.join(github_root, root_candidate, 'areas', area)
          directories(area_root).map { |app| File.join(root_candidate, 'areas', area, app) }
        end
      end

      def directories(path)
        return [] unless Dir.exist?(path)

        (Dir.entries(path) - %w(. ..)).select do |entry|
          File.directory?(File.join(path, entry))
        end
      end
    end
  end
end
