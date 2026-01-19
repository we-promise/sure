class Security < ApplicationRecord
  include Provided

  # ISO 10383 MIC codes mapped to user-friendly exchange names
  # Source: https://www.iso20022.org/market-identifier-codes
  EXCHANGE_NAMES = {
    # United States - NASDAQ family (Operating MIC: XNAS)
    "XNAS" => "NASDAQ",
    "XNGS" => "NASDAQ",       # Global Select Market
    "XNMS" => "NASDAQ",       # Global Market
    "XNCM" => "NASDAQ",       # Capital Market
    "XBOS" => "NASDAQ BX",
    "XPSX" => "NASDAQ PSX",
    "XNDQ" => "NASDAQ Options",

    # United States - NYSE family (Operating MIC: XNYS)
    "XNYS" => "NYSE",
    "ARCX" => "NYSE Arca",
    "XASE" => "NYSE American",  # Formerly AMEX
    "XCHI" => "NYSE Chicago",
    "XCIS" => "NYSE National",
    "AMXO" => "NYSE American Options",
    "ARCO" => "NYSE Arca Options",

    # United States - OTC Markets (Operating MIC: OTCM)
    "OTCM" => "OTC Markets",
    "PINX" => "OTC Pink",
    "OTCQ" => "OTCQX",
    "OTCB" => "OTCQB",
    "PSGM" => "OTC Grey",

    # United States - Other
    "XCBO" => "CBOE",
    "XCME" => "CME",
    "XCBT" => "CBOT",
    "XNYM" => "NYMEX",
    "BATS" => "CBOE BZX",
    "EDGX" => "CBOE EDGX",
    "IEXG" => "IEX",
    "MEMX" => "MEMX",

    # United Kingdom
    "XLON" => "London Stock Exchange",
    "XLME" => "London Metal Exchange",

    # Germany
    "XETR" => "Xetra",
    "XFRA" => "Frankfurt",
    "XSTU" => "Stuttgart",
    "XMUN" => "Munich",
    "XBER" => "Berlin",
    "XHAM" => "Hamburg",
    "XDUS" => "Düsseldorf",
    "XHAN" => "Hannover",

    # Euronext
    "XPAR" => "Euronext Paris",
    "XAMS" => "Euronext Amsterdam",
    "XBRU" => "Euronext Brussels",
    "XLIS" => "Euronext Lisbon",
    "XDUB" => "Euronext Dublin",
    "XOSL" => "Euronext Oslo",
    "XMIL" => "Euronext Milan",

    # Other Europe
    "XSWX" => "SIX Swiss",
    "XVTX" => "SIX Swiss",
    "XMAD" => "BME Madrid",
    "XWBO" => "Vienna",
    "XCSE" => "Copenhagen",
    "XHEL" => "Helsinki",
    "XSTO" => "Stockholm",
    "XICE" => "Iceland",
    "XPRA" => "Prague",
    "XWAR" => "Warsaw",
    "XATH" => "Athens",
    "XIST" => "Istanbul",

    # Canada
    "XTSE" => "Toronto",
    "XTSX" => "TSX Venture",
    "XCNQ" => "CSE",
    "NEOE" => "NEO",

    # Australia & New Zealand
    "XASX" => "ASX",
    "XNZE" => "NZX",

    # Asia - Japan
    "XTKS" => "Tokyo",
    "XJPX" => "Japan Exchange",
    "XOSE" => "Osaka",
    "XNGO" => "Nagoya",
    "XSAP" => "Sapporo",
    "XFKA" => "Fukuoka",

    # Asia - China
    "XSHG" => "Shanghai",
    "XSHE" => "Shenzhen",
    "XHKG" => "Hong Kong",

    # Asia - Other
    "XKRX" => "Korea Exchange",
    "XKOS" => "KOSDAQ",
    "XTAI" => "Taiwan",
    "XSES" => "Singapore",
    "XBKK" => "Thailand",
    "XIDX" => "Indonesia",
    "XKLS" => "Malaysia",
    "XPHS" => "Philippines",
    "XBOM" => "BSE India",
    "XNSE" => "NSE India",

    # Latin America
    "XMEX" => "Mexico",
    "XBUE" => "Buenos Aires",
    "XBOG" => "Colombia",
    "XSGO" => "Santiago",
    "BVMF" => "B3 Brazil",
    "XLIM" => "Lima",

    # Middle East & Africa
    "XTAE" => "Tel Aviv",
    "XDFM" => "Dubai",
    "XADS" => "Abu Dhabi",
    "XSAU" => "Saudi (Tadawul)",
    "XJSE" => "Johannesburg"
  }.freeze

  before_validation :upcase_symbols

  has_many :trades, dependent: :nullify, class_name: "Trade"
  has_many :prices, dependent: :destroy

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :exchange_operating_mic, case_sensitive: false }

  scope :online, -> { where(offline: false) }

  # Returns user-friendly exchange name for a MIC code
  def self.exchange_name_for(mic)
    return nil if mic.blank?
    EXCHANGE_NAMES[mic.upcase] || mic.upcase
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

  def brandfetch_icon_url(width: 40, height: 40)
    return nil unless Setting.brand_fetch_client_id.present? && website_url.present?

    domain = extract_domain(website_url)
    return nil unless domain.present?

    "https://cdn.brandfetch.io/#{domain}/icon/fallback/lettermark/w/#{width}/h/#{height}?c=#{Setting.brand_fetch_client_id}"
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
end
