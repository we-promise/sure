# Institution app icons (512px) from the iTunes Search API, which needs no key.
# Only apps whose developer website is the institution's domain count, so a
# similarly named app from someone else never becomes the logo.
class Account::LogoFetcher::AppStore
  SEARCH_URL = "https://itunes.apple.com/search"
  LOOKUP_URL = "https://itunes.apple.com/lookup"
  ARTWORK_HOST = /\A[a-z0-9-]+\.mzstatic\.com\z/
  MAX_APPS = 3

  def initialize(domain:, term:, countries:, client:)
    @domain = domain
    @term = term
    @countries = countries
    @client = client
  end

  # Countries are searched and icons downloaded at once, so a slow store
  # costs one timeout, not one per request.
  def icons
    apps = in_countries { |country| results(SEARCH_URL, term: @term, country: country, entity: "software", limit: 10) }
    own = apps.uniq { |app| app["trackId"] }.select { |app| own_app?(app) }.first(MAX_APPS)
    @client.in_parallel(own.map { |app| -> { icon_from(app) } }).compact
  end

  def icon(track_id)
    return unless track_id.to_s.match?(/\A\d+\z/)

    app = in_countries { |country| results(LOOKUP_URL, id: track_id, country: country) }.first
    icon_from(app) if app && own_app?(app)
  end

  private
    # Results of every country, in country order.
    def in_countries(&search)
      @client.in_parallel(@countries.map { |country| -> { search.call(country) } }).flatten
    end

    def results(url, params)
      Array(@client.json("#{url}?#{params.to_query}")&.dig("results"))
    end

    def own_app?(app)
      Account::LogoFetcher.same_site?(app["sellerUrl"], @domain)
    end

    def icon_from(app)
      url = app["artworkUrl512"].to_s
      return unless URI.parse(url).then { |uri| uri.scheme == "https" && uri.host.to_s.match?(ARTWORK_HOST) }

      @client.icon(url, key: "appstore:#{app["trackId"]}", source: "appstore", name: app["trackName"],
                        auto: Account::LogoFetcher.own_site?(app["sellerUrl"], @domain))
    rescue URI::InvalidURIError
      nil
    end
end
