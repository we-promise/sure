class Security < ApplicationRecord
  include Provided, PlanRestrictionTracker

  # Transient attribute for search results -- not persisted
  attr_accessor :search_currency

  # ISO 10383 MIC codes mapped to user-friendly exchange names
  # Source: https://www.iso20022.org/market-identifier-codes
  # Data stored in config/exchanges.yml
  EXCHANGES = YAML.safe_load_file(Rails.root.join("config", "exchanges.yml")).freeze

  KINDS = %w[standard cash].freeze

  # Known securities provider keys — derived from the registry so adding a new
  # provider to Registry#available_providers automatically allows it here.
  # Evaluated at runtime (not boot) so runtime-enabled providers are accepted.
  def self.valid_price_providers
    Provider::Registry.for_concept(:securities).provider_keys.map(&:to_s)
  end

  # Builds the Brandfetch crypto URL for a base asset (e.g. "BTC"). Returns
  # nil when Brandfetch isn't configured. Used by Provider::BinancePublic's
  # in-memory search results, by the before_save logo-writer, and by the
  # render-time display_logo_url path. Lives at class level so the search
  # code (which has no instance yet) and instance methods can share it.
  #
  # NOTE: Brandfetch's /crypto/{base} route returns 400 Bad Request on coins
  # it doesn't index — there is no lettermark fallback on that route. We
  # accept the broken-image risk for truly obscure coins (our probe against
  # 37+ popular + memecoin tickers saw zero misses) rather than maintain a
  # probe/cache/column to pre-verify. Mirrors the stocks-with-obscure-ticker
  # tradeoff the app already ships.
  def self.brandfetch_crypto_url(base_asset)
    return nil if base_asset.blank?
    return nil unless Setting.brand_fetch_client_id.present?
    size = Setting.brand_fetch_logo_size
    "https://cdn.brandfetch.io/crypto/#{base_asset}/icon/fallback/lettermark/w/#{size}/h/#{size}?c=#{Setting.brand_fetch_client_id}"
  end

  before_validation :upcase_symbols
  before_save :generate_logo_url_from_brandfetch, if: :should_generate_logo?

  has_many :trades, dependent: :nullify, class_name: "Trade"
  has_many :prices, dependent: :destroy

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :exchange_operating_mic, case_sensitive: false }
  validates :kind, inclusion: { in: KINDS }
  validates :price_provider, inclusion: { in: ->(_) { Security.valid_price_providers } }, allow_nil: true

  scope :online, -> { where(offline: false) }
  scope :standard, -> { where(kind: "standard") }

  # Parses the combobox ID format "SYMBOL|EXCHANGE|PROVIDER" into a hash.
  def self.parse_combobox_id(value)
    parts = value.to_s.split("|", 3)
    { ticker: parts[0].presence, exchange_operating_mic: parts[1].presence, price_provider: parts[2].presence }
  end

  # Lazily finds or creates a synthetic cash security for an account.
  # Used as fallback when creating an interest Trade without a user-selected security.
  def self.cash_for(account)
    ticker = "CASH-#{account.id}".upcase
    find_or_create_by!(ticker: ticker, kind: "cash") do |s|
      s.name = "Cash"
      s.offline = true
    end
  end

  def cash?
    kind == "cash"
  end

  # True when this security represents a crypto asset. Today the only signal
  # is the Binance ISO MIC — when we add a second crypto provider, extend
  # this check rather than duplicating the test at every call site.
  def crypto?
    exchange_operating_mic == Provider::BinancePublic::BINANCE_MIC
  end

  # Strips the display-currency suffix from a crypto ticker (BTCUSD -> BTC,
  # ETHEUR -> ETH). Returns nil for non-crypto securities or when the ticker
  # doesn't end in a supported quote.
  def crypto_base_asset
    return nil unless crypto?
    Provider::BinancePublic::QUOTE_TO_CURRENCY.each_value do |suffix|
      next unless ticker.end_with?(suffix)
      base = ticker.delete_suffix(suffix)
      return base unless base.empty?
    end
    nil
  end

  # Single source of truth for which logo URL the UI should render. Crypto
  # and stocks share the same shape: prefer a freshly computed Brandfetch
  # URL (honors current client_id + size) and fall back to any stored
  # logo_url for the provider-returns-its-own-URL case (e.g. Tiingo S3).
  def display_logo_url
    if crypto?
      self.class.brandfetch_crypto_url(crypto_base_asset).presence || logo_url.presence
    else
      brandfetch_icon_url.presence || logo_url.presence
    end
  end

  # Returns user-friendly exchange name for a MIC code
  def self.exchange_name_for(mic)
    return nil if mic.blank?
    EXCHANGES.dig(mic.upcase, "name") || mic.upcase
  end

  def exchange_name
    self.class.exchange_name_for(exchange_operating_mic)
  end

  def current_price
    @current_price ||= find_or_fetch_price
    return nil if @current_price.nil?
    Money.new(@current_price.price, @current_price.currency)
  end

  def to_combobox_option
    ComboboxOption.new(
      symbol: ticker,
      name: name,
      logo_url: logo_url,
      exchange_operating_mic: exchange_operating_mic,
      country_code: country_code,
      price_provider: price_provider,
      currency: search_currency
    )
  end

  def brandfetch_icon_url(width: nil, height: nil)
    return nil unless Setting.brand_fetch_client_id.present?

    w = width || Setting.brand_fetch_logo_size
    h = height || Setting.brand_fetch_logo_size

    identifier = extract_domain(website_url) if website_url.present?
    identifier ||= ticker

    return nil unless identifier.present?

    "https://cdn.brandfetch.io/#{identifier}/icon/fallback/lettermark/w/#{w}/h/#{h}?c=#{Setting.brand_fetch_client_id}"
  end

  private

    def extract_domain(url)
      uri = URI.parse(url)
      host = uri.host || url
      host.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      nil
    end

    def upcase_symbols
      self.ticker = ticker.upcase
      self.exchange_operating_mic = exchange_operating_mic.upcase if exchange_operating_mic.present?
    end

    def should_generate_logo?
      return false if cash?
      return false unless Setting.brand_fetch_client_id.present?

      return true if logo_url.blank?
      return false unless logo_url.include?("cdn.brandfetch.io")

      website_url_changed? || ticker_changed?
    end

    def generate_logo_url_from_brandfetch
      self.logo_url = if crypto?
        self.class.brandfetch_crypto_url(crypto_base_asset)
      else
        brandfetch_icon_url
      end
    end
end
