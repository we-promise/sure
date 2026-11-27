# Maps moomoo's market numbers, security codes and broker entities onto what
# Sure stores. Including classes that resolve securities define
# `moomoo_account`.
module MoomooAccount::DataHelpers
  extend ActiveSupport::Concern
  include CurrencyNormalizable

  # enable_market numbers of the securities markets, each with the
  # trd_market its fills and orders are queried by. Futures (5), crypto (7),
  # forex (9) and event contracts (17) are left out.
  SECURITIES_MARKETS = {
    1 => "HK",
    2 => "US",
    4 => "HKCC",
    6 => "SG",
    8 => "AU",
    11 => "MY",
    12 => "CA",
    15 => "JP",
    18 => "KR"
  }.freeze
  FUTURES_MARKET = 5
  CRYPTO_MARKET = 7

  # moomoo Japan reports a margin or derivative account's funds and positions
  # one asset category (domestic or foreign) at a time, and requires the
  # category on both calls. Sure doesn't combine the two yet.
  JP_FIRM = "FUTUJP".freeze
  JP_CATEGORIZED_ACC_TYPES = %w[margin derivative].freeze

  # The currency each broker entity's accounts are reported in. moomoo has no
  # CAD, so Canadian accounts report in USD.
  FIRM_HOME_CURRENCY = {
    "FUTUSG" => "SGD",
    "FUTUSECURITIES" => "HKD",
    "FUTUINC" => "USD",
    "FUTUMY" => "MYR",
    "FUTUAU" => "AUD",
    "FUTUJP" => "JPY",
    "FUTUCA" => "USD"
  }.freeze
  DEFAULT_CURRENCY = "USD".freeze

  MALAYSIA = { mic: "XKLS", country: "MY", currency: "MYR", tz: "Asia/Kuala_Lumpur", stock_like: /\A\d{4}[A-Z0-9]{0,2}\z/ }.freeze

  # Security code prefix ("HK" in "HK.00700") → listing venue, the currency the
  # market trades in, the timezone of its trade dates, and the symbols that are
  # plain shares rather than options or warrants.
  CODE_PREFIXES = {
    "HK" => { mic: "XHKG", country: "HK", currency: "HKD", tz: "Asia/Hong_Kong", stock_like: /\A\d{1,5}\z/ },
    "US" => { mic: nil, country: "US", currency: "USD", tz: "America/New_York", stock_like: /\A[A-Z]{1,5}([.\-][A-Z]{1,2})?\z/ },
    "SG" => { mic: "XSES", country: "SG", currency: "SGD", tz: "Asia/Singapore", stock_like: /\A[A-Z0-9]{2,5}\z/ },
    "SH" => { mic: "XSHG", country: "CN", currency: "CNH", tz: "Asia/Shanghai", stock_like: /\A\d{6}\z/ },
    "SZ" => { mic: "XSHE", country: "CN", currency: "CNH", tz: "Asia/Shanghai", stock_like: /\A\d{6}\z/ },
    "JP" => { mic: "XJPX", country: "JP", currency: "JPY", tz: "Asia/Tokyo", stock_like: /\A\d{3}[0-9A-Z]\z/ },
    "AU" => { mic: "XASX", country: "AU", currency: "AUD", tz: "Australia/Sydney", stock_like: /\A[A-Z0-9]{3,6}\z/ },
    "BMS" => MALAYSIA,
    "MY" => MALAYSIA,
    "KR" => { mic: "XKRX", country: "KR", currency: "KRW", tz: "Asia/Seoul", stock_like: /\A\d{6}\z/ },
    "CA" => { mic: nil, country: "CA", currency: "CAD", tz: "America/Toronto", stock_like: /\A[A-Z.]{1,6}\z/ }
  }.freeze

  IMPORTABLE_SECURITY_TYPES = %w[STOCK FUND].freeze
  TRADE_SIDES = { "BUY" => "Buy", "SELL" => "Sell" }.freeze

  HELD_ROW_SECURITY_ID_SQL = "holdings.security_id".freeze
  PROVIDER_ROW_SECURITY_ID_SQL = <<~SQL.squish.freeze
    CASE WHEN holdings.security_locked
      THEN COALESCE(holdings.provider_security_id, holdings.security_id)
      ELSE holdings.security_id
    END
  SQL

  def self.trd_markets_for(enable_markets)
    Array(enable_markets).filter_map { |market| SECURITIES_MARKETS[market.to_i] }.uniq
  end

  # A universal account that also trades futures or crypto is a securities
  # account; its other markets reach Sure only through the account total.
  def self.account_kind_for(enable_markets, security_firm: nil, acc_type: nil)
    markets = Array(enable_markets).map(&:to_i)

    if security_firm.to_s == JP_FIRM && acc_type.to_s.downcase.in?(JP_CATEGORIZED_ACC_TYPES)
      "jp_margin"
    elsif markets.intersect?(SECURITIES_MARKETS.keys)
      "securities"
    elsif markets.include?(FUTURES_MARKET)
      "futures"
    elsif markets.include?(CRYPTO_MARKET)
      "crypto"
    else
      "other"
    end
  end

  private

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.strip : value.to_s
      return nil if normalized.blank?

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    # Splits on the first dot only, so "US.PQR.B" is the US ticker "PQR.B".
    # Returns nil for a code without a known market prefix.
    def parse_code(code)
      prefix, symbol = code.to_s.strip.upcase.split(".", 2)
      return nil if symbol.blank?

      venue = CODE_PREFIXES[prefix]
      return nil unless venue

      # moomoo pads Hong Kong codes to five digits; tickers use four ("0700").
      ticker = prefix == "HK" ? symbol.sub(/\A0+/, "").rjust(4, "0") : symbol
      venue.merge(market: prefix, symbol: symbol, ticker: ticker)
    end

    def stock_like_symbol?(code_info)
      code_info.present? && code_info[:stock_like].match?(code_info[:symbol])
    end

    # Long stock and fund positions. A position without a security type is
    # imported only when its code looks like a plain share.
    def importable_position?(position)
      return false unless position.is_a?(Hash)
      return false unless position["position_side"].blank? || position["position_side"] == "LONG"
      return false unless parse_decimal(position["qty"])&.positive?
      return false if position["code"].blank?

      type = position["security_type"].to_s
      type.present? ? IMPORTABLE_SECURITY_TYPES.include?(type) : stock_like_symbol?(parse_code(position["code"]))
    end

    # The position's market value in its currency: moomoo's market_val, or
    # its quantity at its price when moomoo leaves the value out. nil when
    # neither is there.
    def position_value(position)
      parse_decimal(position["market_val"]) || begin
        quantity = parse_decimal(position["qty"])
        price = parse_decimal(position["nominal_price"])
        quantity * price if quantity && price&.positive?
      end
    end

    def position_currency(position)
      parse_currency(position["currency"]) || parse_code(position["code"])&.dig(:currency)
    end

    # A fill is in its order's currency, else its position's, else its market's.
    def fill_currency(fill, orders, positions_by_code)
      parse_currency(orders.dig(fill["order_id"].to_s, "currency")) ||
        parse_currency(positions_by_code.dig(fill["code"].to_s, "currency")) ||
        parse_code(fill["code"])&.dig(:currency)
    end

    # A cash log row names the currency its running balance is kept in
    # ("Balance: 12.34 USD").
    def cash_log_currency(row)
      row["balance"].to_s[/\b([A-Z]{3})\s*\z/, 1]
    end

    # What a buy or sell fill of a stock or fund trades, or the reason it
    # isn't imported as a trade: short sales, buy-backs and derivatives aren't.
    def trade_fill_details(fill, orders, positions_by_code)
      info = parse_code(fill["code"])
      return :unknown_market unless info

      side = fill["trd_side"].to_s
      return :short_side unless TRADE_SIDES.key?(side)

      order = orders[fill["order_id"].to_s] || {}
      position = positions_by_code[fill["code"].to_s] || {}
      type = order["security_type"].presence || position["security_type"].presence
      return :not_stock unless type ? IMPORTABLE_SECURITY_TYPES.include?(type) : stock_like_symbol?(info)

      quantity = parse_decimal(fill["qty"])
      price = parse_decimal(fill["price"])
      return :bad_numbers unless quantity&.positive? && price&.positive?

      date = trade_date(fill["create_time"], info[:tz])
      return :bad_time unless date

      { info: info, side: side, buy: side == "BUY", quantity: quantity, price: price, gross: quantity * price, date: date,
        currency: fill_currency(fill, orders, positions_by_code) }
    end

    def trade_date(micros, timezone)
      Provider::Moomoo.from_micros(micros)&.in_time_zone(timezone)&.to_date
    end

    # provider_row: true is for holdings, see #held_security_for.
    def security_for_code(code, name, provider_row: false)
      @securities ||= {}
      @securities[[ code.to_s, provider_row ]] ||= held_security_for(code.to_s, provider_row: provider_row) || resolve_security(code.to_s, name)
    end

    # The security this account already holds or traded the code as, so a
    # code never moves to another row. A provider match is stored under the
    # provider's own ticker (Yahoo's 0700.HK), which a lookup by moomoo's bare
    # ticker can't find: without this every sync would search again, and one
    # failed search would leave the code on a new offline security, its
    # history split across the two.
    #
    # With provider_row: true, a holding the user remapped answers with the
    # security moomoo's code was imported as, which is what the import adapter
    # carries the remap forward from. Trades follow the remap.
    def held_security_for(code, provider_row:)
      account = moomoo_account.current_account
      return nil unless account

      prefix = Holding.sanitize_sql_like("#{holding_external_id_prefix}#{code}_")
      security_id = account.holdings
        .where("holdings.external_id LIKE ?", "#{prefix}%")
        .order(date: :desc)
        .pick(Arel.sql(provider_row ? PROVIDER_ROW_SECURITY_ID_SQL : HELD_ROW_SECURITY_ID_SQL))
      security_id ||= traded_security_id_for(account, code)
      security_id && Security.find_by(id: security_id)
    end

    def traded_security_id_for(account, code)
      external_ids = moomoo_account.fills.filter_map { |fill| fill_external_id(fill) if fill["code"].to_s == code }
      return nil if external_ids.empty?

      account.trades.where(entries: { source: "moomoo", external_id: external_ids }).order("entries.date DESC").pick("trades.security_id")
    end

    # A holding's external id is the prefix, its code and its date.
    def holding_external_id_prefix
      "moomoo_holding_#{moomoo_account.moomoo_account_id}_"
    end

    def fill_external_id(fill)
      "moomoo_fill_#{moomoo_account.moomoo_account_id}_#{fill['deal_id']}"
    end

    def resolve_security(code, name)
      info = parse_code(code)
      return offline_security("MOOMOO:#{code}", name, mic: nil) unless info

      security = Security::Resolver.new(info[:ticker], exchange_operating_mic: info[:mic], country_code: info[:country]).resolve
      return offline_security(info[:ticker], name, mic: info[:mic]) unless security

      security.update!(name: name) if security.offline? && security.name.blank? && name.present?
      security
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "moomoo code #{code} could not be resolved: #{e.class} - #{e.message}",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { code: code, mic: info&.dig(:mic) }
      )
      offline_security(info ? info[:ticker] : "MOOMOO:#{code}", name, mic: info&.dig(:mic))
    end

    def offline_security(ticker, name, mic:)
      security = Security.find_or_initialize_by_ticker_and_exchange(ticker: ticker, exchange_operating_mic: mic)
      security.name ||= name.presence || ticker
      security.offline = true if security.new_record?
      security.save! if security.changed?
      security
    end
end
