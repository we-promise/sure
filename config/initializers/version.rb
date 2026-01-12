module Sure
  class << self
    def version
      Semver.new(semver)
    end

    def commit_sha
      if Rails.env.production?
        ENV["BUILD_COMMIT_SHA"]
      else
        `git rev-parse HEAD`.chomp
      end
    end

    private
      def semver
        # Read from shared VERSION file at repo root
        version_file = Rails.root.join("VERSION")
        if version_file.exist?
          version_file.read.strip
        else
          "0.0.0"
        end
      end
  end
end
