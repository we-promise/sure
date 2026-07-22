class Provider::Github
  CACHE_TTL = 2.hours

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
    begin
      Rails.cache.fetch(release_notes_cache_key, expires_in: CACHE_TTL) do
        release = client.releases(repo).first
        if release
          {
            avatar: release.author.avatar_url,
            # this is the username, it would be nice to get the full name
            username: release.author.login,
            name: release.name,
            published_at: release.published_at,
            body: client.markdown(release.body, mode: "gfm", context: repo)
          }
        else
          nil
        end
      end
    rescue => e
      Rails.logger.error "Failed to fetch latest GitHub release notes: #{e.message}"
      nil
    end
  end

  private
    def repo
      "#{owner}/#{name}"
    end

    def release_notes_cache_key
      "latest_github_release_notes/#{repo}"
    end
end
