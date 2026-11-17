# Institution app icons (512px) from RuStore, the Russian Android store that
# lists banks missing from Google Play and the App Store. Its catalogue search
# needs no key but returns no developer details, and its store pages sit
# behind a bot challenge, so apps are matched on what the search returns:
# a package name holding the domain's brand ("com.yandex.bank" for
# bank.yandex.ru), an app name starting with the institution's ("Т-Банк:
# карты, вклады, кредиты"), and other apps of the brands found that way
# ("ru.tinkoff.sme" next to "com.idamob.tinkoff.android"). Anyone can choose
# such names, so Account::LogoFetcher offers these icons in the picker only.
class Account::LogoFetcher::RuStore
  SEARCH_URL = "https://backapi.rustore.ru/applicationData/apps"
  ICON_HOST = "static.rustore.ru"
  PACKAGE_FORMAT = /\A[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+\z/
  # Domain labels and package segments that name no one in particular.
  GENERIC_NAMES = %w[www com net org ru kz by ua bank online finance app apps android mobile my].freeze
  MAX_APPS = 3

  def initialize(domain:, term:, client:)
    @domain = domain
    @term = term
    @client = client
  end

  def icons
    @client.in_parallel(own_apps.first(MAX_APPS).map { |app| -> { icon_from(app) } }).compact
  end

  # RuStore has no public lookup by package, so the picked app is found again
  # through the same search that listed it.
  def icon(package)
    app = own_apps.find { |candidate| candidate["packageName"] == package }
    icon_from(app) if app
  end

  private
    def own_apps
      apps = Array(@client.json("#{SEARCH_URL}?#{{ query: @term, pageSize: 10 }.to_query}")&.dig("body", "content"))
        .select { |app| app["packageName"].to_s.match?(PACKAGE_FORMAT) }
      named = apps.select { |app| simplify(app["appName"]).start_with?(simplify(@term)) && simplify(@term).present? }
      brands = names(@domain.split(".")[0...-1]) + named.flat_map { |app| names(app["packageName"].split(".")) }

      apps.select { |app| named.include?(app) || branded?(app["packageName"], brands) }
    end

    def branded?(package, brands)
      segments = package.downcase.split(".")
      brands.any? { |brand| segments.any? { |segment| segment.start_with?(brand) } }
    end

    def names(parts)
      parts.map(&:downcase).select { |part| part.length >= 3 } - GENERIC_NAMES
    end

    # "Т-Банк: карты" and "т банк" both become "тбанк…".
    def simplify(name)
      name.to_s.downcase.gsub(/[^[:alnum:]]/, "")
    end

    def icon_from(app)
      url = app["iconUrl"].to_s
      return unless URI.parse(url).then { |uri| uri.scheme == "https" && uri.host == ICON_HOST }

      @client.icon(url, key: "rustore:#{app["packageName"]}", source: "rustore", name: app["appName"])
    rescue URI::InvalidURIError
      nil
    end
end
