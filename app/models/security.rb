class Security < ApplicationRecord
  include Provided, PlanRestrictionTracker

  # ISO 10383 MIC codes mapped to user-friendly exchange names
  # Source: https://www.iso20022.org/market-identifier-codes
  # Data stored in config/exchanges.yml
  EXCHANGES = YAML.safe_load_file(Rails.root.join("config", "exchanges.yml")).freeze

  before_validation :upcase_symbols
  before_save :generate_logo_url_from_brandfetch, if: :should_generate_logo?

  has_many :trades, dependent: :nullify, class_name: "Trade"
  has_many :prices, dependent: :destroy

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :exchange_operating_mic, case_sensitive: false }

  scope :online, -> { where(offline: false) }

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
      country_code: country_code
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
      url = brandfetch_icon_url
      return false unless url.present?

      return true if logo_url.blank?
      return false unless logo_url.include?("cdn.brandfetch.io")

      website_url_changed? || ticker_changed?
    end

    def generate_logo_url_from_brandfetch
      self.logo_url = brandfetch_icon_url
    end
end
