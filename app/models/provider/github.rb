class Provider::Github
  attr_reader :name, :owner, :branch, :client

  def initialize
    @name = "sure"
    @owner = "we-promise"
    @branch = "main"
    @client = Octokit::Client.new(
      connection_options: {
        request: {
          open_timeout: 10,
          timeout: 10
        }
      }
    )
  end

  def fetch_latest_release_notes
    fetch_cached_release_notes("latest_github_release_notes") do
      client.releases(repo).first
    end
  end

  # Release notes for one exact release tag (e.g. "v0.7.5-alpha.7"), so the
  # "What's new" highlight always reflects the deployed build rather than
  # whatever happens to be the newest release on GitHub.
  def fetch_release_notes(tag)
    fetch_cached_release_notes("github_release_notes_#{tag}") do
      client.release_for_tag(repo, tag)
    end
  end

  private
    def repo
      "#{owner}/#{name}"
    end

    # Caches both hits (2h) and misses/failures (5min, as a false sentinel):
    # without the sentinel, a missing tag or GitHub outage would retry the
    # outbound call on every user's first interaction of every page.
    def fetch_cached_release_notes(cache_key)
      cached = Rails.cache.read(cache_key)
      return cached.presence unless cached.nil?

      release = yield
      notes = release && serialize_release_notes(release)
      Rails.cache.write(cache_key, notes || false, expires_in: notes ? 2.hours : 5.minutes)
      notes
    rescue => e
      Rails.logger.error "Failed to fetch GitHub release notes (#{cache_key}): #{e.message}"
      Rails.cache.write(cache_key, false, expires_in: 5.minutes)
      nil
    end

    def serialize_release_notes(release)
      {
        avatar: release.author.avatar_url,
        # this is the username, it would be nice to get the full name
        username: release.author.login,
        name: release.name,
        published_at: release.published_at,
        body: client.markdown(release.body, mode: "gfm", context: repo)
      }
    end
end
