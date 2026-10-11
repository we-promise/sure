# Institution app icons from Google Play. There is no public API, so this
# reads the store pages' meta tags (developer website and icon), which have
# stayed stable while the page layout around them changes. Only apps whose
# developer website is the institution's domain count.
class Account::LogoFetcher::GooglePlay
  SEARCH_URL = "https://play.google.com/store/search"
  APP_URL = "https://play.google.com/store/apps/details"
  PACKAGE_FORMAT = /\A[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+\z/
  ICON_FORMAT = %r{\Ahttps://play-lh\.googleusercontent\.com/[\w-]+\z}
  MAX_APPS = 3

  def initialize(domain:, term:, country:, client:)
    @domain = domain
    @term = term
    @country = country
    @client = client
  end

  def icons
    page = @client.get("#{SEARCH_URL}?#{{ q: @term, c: "apps", hl: "en", gl: @country }.to_query}")&.body.to_s
    packages = page.scan(%r{/store/apps/details\?id=([\w.]+)}).flatten.uniq.first(MAX_APPS)
    @client.in_parallel(packages.map { |package| -> { icon(package) } }).compact
  end

  def icon(package)
    return unless package.to_s.match?(PACKAGE_FORMAT)

    page = @client.get("#{APP_URL}?#{{ id: package, hl: "en" }.to_query}")&.body.to_s
    developer_url = meta(page, "name", "appstore:developer_url")
    icon_url = meta(page, "property", "og:image").to_s.split("=").first
    return unless Account::LogoFetcher.same_site?(developer_url, @domain) && icon_url.to_s.match?(ICON_FORMAT)

    name = meta(page, "property", "og:title").to_s.delete_suffix(" - Apps on Google Play").presence
    @client.icon("#{icon_url}=s512", key: "googleplay:#{package}", source: "googleplay", name: name,
                                     auto: Account::LogoFetcher.own_site?(developer_url, @domain))
  end

  private
    def meta(page, attribute, value)
      content = page[/<meta #{attribute}="#{Regexp.escape(value)}" content="([^"]*)"/, 1]
      CGI.unescapeHTML(content) if content
    end
end
