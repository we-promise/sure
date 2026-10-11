# Finds an institution's icon and stores it as the account's own logo.
# Brandfetch refuses server-side downloads and bank sites block bots, so the
# icons come from services that already collected them: favicon services
# (the sites' touch and manifest icons) and the institution's mobile apps in
# the App Store, Google Play and RuStore, matched by the developer's website
# (or, in RuStore, by the package name).
class Account::LogoFetcher
  FAVICON_SOURCES = {
    "google" => ->(domain) { "https://www.google.com/s2/favicons?domain=#{domain}&sz=256" },
    "duckduckgo" => ->(domain) { "https://icons.duckduckgo.com/ip3/#{domain}.ico" },
    "yandex" => ->(domain) { "https://favicon.yandex.net/favicon/v2/#{domain}?size=120" }
  }.freeze

  DOMAIN_FORMAT = /\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/
  # Country-code TLDs that differ from the ISO country code the stores use.
  CCTLD_COUNTRIES = { "uk" => "gb" }.freeze

  # `key` identifies the icon for fetch(source:): a favicon service name, or
  # "appstore:<track id>", "googleplay:<package>" or "rustore:<package>" for an app.
  # `auto` is false for icons only offered in the picker, never picked automatically.
  Icon = Data.define(:key, :source, :name, :body, :size, :content_type, :extension, :auto) do
    def initialize(auto: true, **attributes)
      super
    end
  end

  attr_reader :account

  # The developer site is the institution's domain or one of its subdomains.
  def self.own_site?(host, domain)
    host = Account.normalize_institution_domain(host)
    host.present? && (host == domain || host.end_with?(".#{domain}"))
  end

  # Also a parent of the domain: Ozon Bank's apps list ozon.ru for
  # finance.ozon.ru. A parent can be shared by unrelated sites (yandex.ru
  # for every Yandex app, github.io), so such apps are offered in the picker
  # but never picked automatically.
  def self.same_site?(host, domain)
    host = Account.normalize_institution_domain(host)
    own_site?(host, domain) || (host.present? && domain.end_with?(".#{host}"))
  end

  def initialize(account)
    @account = account
  end

  # Real icons from every source, largest first; ties keep the source order.
  # RuStore is asked only for the picker: it may match an app by its package
  # name, which anyone can choose, and it puts clients that read many of its
  # store pages behind a bot challenge.
  def candidates(for_picker: true)
    return [] unless domain

    # Built here, not in the threads, so database reads stay on this thread's connection.
    stores = [ app_store, google_play, (ru_store if for_picker) ].compact
    icons = client.in_parallel([ -> { favicon_icons }, *stores.map { |store| -> { store.icons } } ]).flatten
    icons.each_with_index.sort_by { |icon, index| [ -icon.size, index ] }.map(&:first)
  end

  # Attaches the icon with `source` key, or the largest one fit for an
  # automatic pick when no source is given. `auto` marks the icon as picked by Sure,
  # so later automatic fetches may replace it. Returns true when an icon was
  # attached.
  def fetch(source: nil, auto: false)
    return false unless domain

    fetched_for = domain
    logo_before = logo_state
    icon = source ? icon_for(source) : candidates(for_picker: false).find(&:auto)
    return false unless icon

    # The search takes seconds. Under the row lock, which the account form's
    # save also holds, a fetch yields to an icon chosen, uploaded or removed
    # meanwhile and to a domain changed meanwhile. Touching the account busts
    # the sidebar cache, which an attachment alone does not.
    account.with_lock do
      if logo_state != logo_before || account.institution_domain != fetched_for || (auto && !account.logo_auto_fetchable?)
        false
      else
        account.logo.attach(
          io: StringIO.new(icon.body),
          filename: "#{fetched_for}.#{icon.extension}",
          content_type: icon.content_type,
          metadata: { "logo_source" => icon.source, "logo_key" => icon.key, "logo_name" => icon.name,
                      "logo_domain" => fetched_for, "logo_auto" => auto }.compact
        ) && account.update!(prefer_brandfetch_logo: false, updated_at: Time.current)
      end
    end
  end

  private
    def logo_state
      [ account.logo.attachment&.blob_id, account.prefer_brandfetch_logo? ]
    end

    def domain
      value = account.institution_domain
      value if value.to_s.match?(DOMAIN_FORMAT)
    end

    def icon_for(key)
      group, id = key.to_s.split(":", 2)

      case group
      when *FAVICON_SOURCES.keys then favicon_icon(group) if id.nil?
      when "appstore" then app_store.icon(id)
      when "googleplay" then google_play.icon(id)
      when "rustore" then ru_store.icon(id)
      end
    end

    def favicon_icons
      FAVICON_SOURCES.keys.filter_map { |source| favicon_icon(source) }
    end

    def favicon_icon(source)
      client.icon(FAVICON_SOURCES.fetch(source).call(domain), key: source, source: source)
    end

    def app_store
      @app_store ||= Account::LogoFetcher::AppStore.new(domain:, term: search_term, countries:, client:)
    end

    def google_play
      @google_play ||= Account::LogoFetcher::GooglePlay.new(domain:, term: search_term, country: countries.first, client:)
    end

    def ru_store
      @ru_store ||= Account::LogoFetcher::RuStore.new(domain:, term: search_term, client:)
    end

    def search_term
      account.institution_name.presence || domain.split(".").first
    end

    # App catalogues differ per country: the domain's own country ("bankffin.kz"),
    # the family's, then the US store, which lists most international apps.
    def countries
      tld = domain.split(".").last
      tld = CCTLD_COUNTRIES.fetch(tld, tld)
      [ (tld if tld.length == 2), account.family&.country, "us" ].compact.map(&:downcase).uniq
    end

    def client
      @client ||= Account::LogoFetcher::Client.new
    end
end
