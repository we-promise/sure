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
      FALLBACK_VERSION = "0.7.0-alpha.4".freeze

      def semver
        stripped_content = Rails.root.join(".sure-version").read.strip
        stripped_content.present? ? stripped_content : FALLBACK_VERSION
      end
  end
end
