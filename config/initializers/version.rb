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
    rescue Errno::ENOENT
      nil
    end

    private
      def semver
        stripped_content = Rails.root.join(".sure-version").read.strip
        stripped_content.presence || "0.0.0-dev"
      rescue Errno::ENOENT
        "0.0.0-dev"
      end
  end
end
