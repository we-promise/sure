module EtoroAccount::DataHelpers
  extend ActiveSupport::Concern

  # eToro's instrumentTypeID for crypto. These instruments resolve to the
  # shared CRYPTO:<SYMBOL> securities rather than to an exchange listing.
  CRYPTO_TYPE_ID = 10

  # The namespace of the securities a connection keeps as eToro's own (see
  # #own_security), and of the placeholders for instruments without a
  # symbol. No price provider lists a ticker in it.
  OWN_TICKER_PREFIX = "ETORO:".freeze

  # The instrument types eToro settles as owned assets: stocks, ETFs and
  # crypto. Currencies (1), commodities (2) and indices (4) are CFDs only.
  REAL_ASSET_TYPE_IDS = [ 5, 6, CRYPTO_TYPE_ID ].freeze

  # settlementTypeID of an owned asset. The others are CFDs (0), swaps (2),
  # crypto margin trades (3) and futures (4).
  REAL_ASSET_SETTLEMENT_TYPE = 1

  # Operating MIC of each venue eToro reports as an instrument's exchangeID.
  EXCHANGE_ID_MICS = {
    4 => "XNAS",
    5 => "XNYS",
    6 => "XETR",
    7 => "XLON",
    9 => "XPAR",
    12 => "XSWX",
    14 => "XOSL",
    15 => "XSTO",
    16 => "XCSE",
    17 => "XHEL",
    21 => "XHKG",
    23 => "XBRU",
    30 => "XAMS",
    39 => "XDFM"
  }.freeze

  # Nasdaq, NYSE and the regular-trading-hours lines eToro lists beside them.
  US_EXCHANGE_IDS = [ 4, 5, 33 ].freeze

  # Suffixes eToro adds to US listings that are not part of the ticker, as in
  # ABCD.RTH, EFGH.US and IJKL.CH.
  US_LISTING_SUFFIXES = %w[RTH US CH].freeze

  class << self
    # Securities eToro's trades and holdings have left, as after a change of
    # EtoroItem#own_securities or of how a symbol resolves, go when nothing
    # holds or trades them any more: left behind, an online one costs the
    # price provider a details request on every market-data run and an
    # offline one a health check, and one of eToro's own is of no use to
    # anyone else. A holding of zero units in one of `accounts` does not
    # count as holding it: the holdings import closes a holding eToro
    # stopped reporting with one, and the balances carry it over the days
    # before, so such rows go with the security, as do its prices. A holding
    # a user moved to another security keeps the one it was reported as, and
    # one something took up meanwhile stays.
    def discard_unused_securities(security_ids, accounts: [])
      account_ids = Array(accounts).map { |account| account.respond_to?(:id) ? account.id : account }

      Security.where(id: Array(security_ids).uniq).where.not(kind: "cash").find_each do |security|
        next if Trade.exists?(security_id: security.id)
        next if Holding.where(provider_security_id: security.id).where.not(security_id: security.id).exists?

        rows = Holding.where(security_id: security.id)
        next if rows.where.not(qty: 0).or(rows.where.not(account_id: account_ids)).exists?

        Security.transaction do
          rows.delete_all
          Security::Price.where(security_id: security.id).delete_all
          security.destroy!
        end
      rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed
        next
      end
    end
  end

  # Venue suffixes eToro appends to non-US symbols ("LNDA.L", "NOPQ.DE"), for
  # instruments whose exchangeID has no MIC above.
  EXCHANGE_SUFFIX_MICS = {
    "L" => "XLON",
    "DE" => "XETR",
    "PA" => "XPAR",
    "MI" => "XMIL",
    "MC" => "XMAD",
    "NV" => "XAMS",
    "BR" => "XBRU",
    "LSB" => "XLIS",
    "ZU" => "XSWX",
    "ST" => "XSTO",
    "OL" => "XOSL",
    "CO" => "XCSE",
    "HE" => "XHEL",
    "HK" => "XHKG",
    "AE" => "XDFM"
  }.freeze

  private

    # eToro's documents disagree on key casing ("positionID" in the schema,
    # "positionId" in its examples), so fields are looked up case-insensitively.
    def field(hash, name)
      return nil unless hash.is_a?(Hash)
      return hash[name] if hash.key?(name)

      key = hash.keys.find { |candidate| candidate.to_s.casecmp?(name) }
      key.nil? ? nil : hash[key]
    end

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.strip : value.to_s
      return nil if normalized.blank?

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    # eToro's timestamps are UTC and its daily balances are UTC days, so a
    # timestamp is dated by its UTC day whatever zone the caller runs in.
    def parse_date(value)
      return nil if value.blank?

      case value
      when DateTime, Time, ActiveSupport::TimeWithZone
        value.in_time_zone("UTC").to_date
      when Date
        value
      else
        parse_time(value)&.to_date || Date.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end

    # A timestamp without a zone of its own is taken as UTC.
    def parse_time(value)
      ActiveSupport::TimeZone["UTC"].parse(value.to_s)
    end

    # The trading day eToro counts a moment towards. Its daily candles run
    # from 17:00 New York time to 17:00 the next day, dated by the day they
    # end, whatever the venue.
    def session_date(value)
      time = value.is_a?(String) ? parse_time(value) : value
      time && (time.in_time_zone("America/New_York") + 7.hours).to_date
    rescue ArgumentError
      nil
    end

    # How many shares one share of the instrument held at the end of `date`
    # is today: the product of the splits eToro's prices show after that day
    # (see EtoroItem::PriceHistoryImporter). eToro restates an open position
    # on today's shares, but a closed one keeps the units it closed with. On
    # the day eToro's prices switch to the new shares, which can be a trading
    # day before the exchange's, a leg closed before the switch is on the old
    # ones: its price (`rate`) is nearer theirs. Splits a price provider's
    # stored prices are as traded across are left out (`as_traded`).
    def split_factor_after(instrument_id, date, rate: nil)
      history = split_history_of(instrument_id)
      return Rational(1) if date.nil? || history["splits"].blank?

      as_traded = Array(history["as_traded"])
      history["splits"].reduce(Rational(1)) do |factor, (on, ratio, close)|
        switch = Date.iso8601(on)
        ratio = Rational(ratio)
        after = switch > date || (switch == date && before_switch?(rate, ratio, close))
        after && !as_traded.include?(on) ? factor * ratio : factor
      end
    end

    # The split checks a closed leg follows: those of the instrument whose
    # closes price its security, as the security's prices follow them (ABCD
    # for a leg of ABCD.RTH), and otherwise its own.
    def split_history_of(instrument_id)
      security = trade_security_for(instrument_id)
      pricing = security && pricing_histories[security.id]
      return pricing if pricing&.key?("splits")

      price_history_of(instrument_id)
    end

    def pricing_histories
      @pricing_histories ||= instruments_map.each_key.with_object({}) do |instrument_id, histories|
        history = price_history_of(instrument_id)
        histories[history["security_id"]] = history if history["security_id"].present?
      end
    end

    def price_history_of(instrument_id)
      details = instruments_map[instrument_id.to_s]
      history = details["price_history"] if details.is_a?(Hash)
      history.is_a?(Hash) ? history : {}
    end

    # Whether a trade on a split's switch day went through at a price nearer
    # the old shares' than the switch day's close on the new ones.
    def before_switch?(rate, ratio, close)
      rate = parse_decimal(rate)
      close = parse_decimal(close)
      return false unless rate&.positive? && close&.positive?

      Math.log(rate.to_f / (close.to_f * ratio.to_f)).abs < Math.log(rate.to_f / close.to_f).abs
    end

    # eToro's schema nests pnL under unrealizedPnL, while its example response
    # puts it on the position itself. Both are accepted, nested first.
    def position_pnl(position)
      parse_decimal(field(field(position, "unrealizedPnL"), "pnL")) || parse_decimal(field(position, "pnL")) || BigDecimal("0")
    end

    # Cost of the units still open. After a partial close, amount and
    # initialAmountInDollars still describe the whole original position.
    def position_cost(position)
      parse_decimal(field(position, "unitsBaseValueDollars")) || parse_decimal(field(position, "amount"))
    end

    # settlementTypeID by position ID for the positions given.
    def settlement_types_of(positions)
      Array(positions).each_with_object({}) do |position, types|
        position_id = field(position, "positionID").to_s
        settlement_type = field(position, "settlementTypeID")
        types[position_id] = settlement_type.to_i if position_id.present? && !settlement_type.nil?
      end
    end

    # The settlementTypeID of every position seen open, on this sync or an
    # earlier one.
    def known_settlement_types
      @known_settlement_types ||= begin
        owner = @etoro_account.positions_owner
        (owner.position_settlement_types || {}).merge(settlement_types_of(owner.raw_positions_payload))
      end
    end

    # Whether an open position or a closed trade is an owned asset rather
    # than a CFD. The settlement type decides when it is known: an open
    # position reports it, and a closed trade takes it from its position as
    # seen open. A position never seen open counts as owned only as an
    # unleveraged long on a stock, ETF or crypto instrument, so a CFD of that
    # kind that opened and closed between two syncs is still imported.
    def real_asset?(record)
      settlement_type = field(record, "settlementTypeID")
      settlement_type = known_settlement_types[field(record, "positionID").to_s] if settlement_type.nil?
      return settlement_type.to_i == REAL_ASSET_SETTLEMENT_TYPE unless settlement_type.nil?

      unleveraged_long?(record) && REAL_ASSET_TYPE_IDS.include?(instrument_type_id(field(record, "instrumentID")))
    end

    def unleveraged_long?(record)
      field(record, "isBuy") == true && field(record, "leverage").to_i <= 1
    end

    def instrument_type_id(instrument_id)
      instruments_map.dig(instrument_id.to_s, "type_id")&.to_i
    end

    # Kept in @securities by instrument ID. EtoroAccount::Processor gives its
    # holdings and activities imports one hash, so an instrument resolves
    # once in a run and its trades go where its holding went.
    def security_for_instrument(instrument_id)
      @securities ||= {}
      key = instrument_id.to_s
      return @securities[key] if @securities.key?(key)

      @securities[key] = resolve_security(key)
    end

    # The security an instrument's trades go on: the one it resolves to, or
    # the one a user moved its holding to. Holding#remap_security! takes the
    # trades along, and the holdings import carries the move to each new
    # day's holding, so the trades stay with the holding.
    def trade_security_for(instrument_id)
      security = security_for_instrument(instrument_id)
      security && (remapped_securities[security.id] || security)
    end

    # The securities users moved eToro's holdings to, by the ID of the
    # security eToro reported each one as. The newest holding of a reported
    # security decides: the holdings import carries a move to each new day's
    # holding, and when it does not, the trades go back with the holding.
    def remapped_securities
      return {} unless provider_id

      @remapped_securities ||= begin
        newest = account.holdings
          .where(account_provider_id: provider_id)
          .where.not(provider_security_id: nil)
          .select("DISTINCT ON (holdings.provider_security_id) holdings.provider_security_id, holdings.security_id, holdings.security_locked")
          .order("holdings.provider_security_id", date: :desc, id: :desc)
          .to_a
        moved = newest.select { |holding| holding.security_locked? && holding.security_id != holding.provider_security_id }
        securities = Security.where(id: moved.map(&:security_id)).index_by(&:id)
        moved.to_h { |holding| [ holding.provider_security_id, securities[holding.security_id] ] }.compact
      end
    end

    # The security an instrument is held as. Nil while eToro has not described
    # the instrument yet: it is left for a later sync rather than tied to a
    # placeholder that every stored trade would keep.
    def resolve_security(instrument_id)
      instrument = instruments_map[instrument_id]
      return nil if instrument.nil?

      name = instrument["name"]
      symbol = instrument["symbol"].to_s.strip.upcase
      return offline_security("ETORO:#{instrument_id}", name) if symbol.blank?
      return own_security(symbol, instrument, name) if own_securities?

      if instrument["type_id"].to_i == CRYPTO_TYPE_ID
        return Onchain::SecurityResolver.resolve(symbol: symbol, name: name) || offline_security("ETORO:#{instrument_id}", name)
      end

      ticker, mic = listing(symbol, instrument["exchange_id"])
      return name_offline_security(Security::Resolver.new(ticker).resolve, name) unless mic

      security = Security::Resolver.new(ticker, exchange_operating_mic: mic).resolve
      return name_offline_security(security, name) unless listed_elsewhere?(security, mic)

      discard_unused_match(security)
      venue_security(ticker, mic, name)
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "eToro instrument #{instrument_id} (#{symbol}) could not be resolved: #{e.class} - #{e.message}",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: { instrument_id: instrument_id, symbol: symbol, etoro_account_id: @etoro_account&.id }
      )
      placeholder = symbol.blank? || instrument&.dig("type_id").to_i == CRYPTO_TYPE_ID
      offline_security(placeholder ? "ETORO:#{instrument_id}" : symbol, instrument&.dig("name"))
    end

    # Ticker and operating MIC of the listing an eToro symbol stands for. The
    # exchangeID names the venue, with the symbol's suffix (the part after
    # its last dot) as the fallback. A single-letter suffix that is not a
    # venue is a share class (PQR.B) and stays in the ticker, also when
    # another suffix follows it (PQR.B.RTH, QRS.A.L).
    def listing(symbol, exchange_id)
      mic = EXCHANGE_ID_MICS[exchange_id.to_i]
      base, _dot, suffix = symbol.rpartition(".")
      return [ symbol, mic ] if base.blank? || suffix.blank?

      if US_LISTING_SUFFIXES.include?(suffix) && US_EXCHANGE_IDS.include?(exchange_id.to_i)
        return [ base, mic || us_listing_mic(base) ]
      end

      suffix_mic = EXCHANGE_SUFFIX_MICS[suffix]
      return [ base, mic || suffix_mic ] if suffix_mic
      return [ symbol, mic ] if suffix.length == 1
      return [ base, mic ] if mic

      [ symbol, nil ]
    end

    # A US line without a venue of its own (ABCD.RTH) takes the venue of the
    # plain listing eToro also carries, so both resolve to one security.
    def us_listing_mic(base)
      instruments_map.each_value do |instrument|
        next unless instrument["symbol"].to_s.strip.upcase == base

        mic = EXCHANGE_ID_MICS[instrument["exchange_id"].to_i]
        return mic if mic
      end

      nil
    end

    # Security::Resolver ranks an exact ticker on any venue above the venue
    # asked for, and Yahoo Finance names lines outside the US with a venue
    # suffix (QZX.L), so a search for London's QZX can come back as the QZX on
    # NYSE. A listing in another country is never the line eToro holds.
    def listed_elsewhere?(security, mic)
      wanted = mic_country(mic)
      found = mic_country(security&.exchange_operating_mic) || security&.country_code.presence
      wanted.present? && found.present? && !wanted.casecmp?(found)
    end

    # The line on eToro's venue, named by eToro. It is priced when the
    # securities provider lists the ticker there (Yahoo Finance adds its venue
    # suffix itself), and kept offline when no provider does.
    def venue_security(ticker, mic, name)
      security = Security.find_or_initialize_by_ticker_and_exchange(ticker: ticker, exchange_operating_mic: mic)
      if security.new_record?
        line = provider_venue_line(ticker, mic)
        security.country_code = mic_country(mic)
        security.price_provider = line&.price_provider
        security.offline = line.nil?
      end
      security.name = name.presence || ticker if security.name.blank?
      security.save! if security.changed?
      security
    end

    def provider_venue_line(ticker, mic)
      Security.search_provider(ticker, exchange_operating_mic: mic).find do |line|
        line_ticker = line.ticker.to_s.upcase
        (line_ticker == ticker || line_ticker.start_with?("#{ticker}.")) && !listed_elsewhere?(line, mic)
      end
    end

    def mic_country(mic)
      Security::EXCHANGES.dig(mic.to_s.upcase, "country") if mic.present?
    end

    # Whether the connection keeps eToro's instruments as securities of its
    # own (EtoroItem#own_securities), apart from the securities the price
    # providers and the other accounts share.
    def own_securities?
      @etoro_account&.etoro_item&.own_securities? || false
    end

    # The connection's own security for an instrument: the listing eToro's
    # symbol stands for, named in eToro's namespace (ETORO:ABCD on Nasdaq,
    # ETORO:LNDA on London, crypto as ETORO:XCN), which no price provider
    # lists, so that none is asked about it, no health check brings it
    # online and only eToro prices it (see EtoroItem::PriceHistoryImporter).
    # It is created offline with eToro's pricing reason, and keeps the venue
    # and country of the listing. The lines eToro lists beside a listing
    # (ABCD.RTH) resolve to the listing's security, as they do otherwise.
    def own_security(symbol, instrument, name)
      ticker, mic = instrument["type_id"].to_i == CRYPTO_TYPE_ID ? [ symbol, nil ] : listing(symbol, instrument["exchange_id"])
      security = Security.find_or_initialize_by_ticker_and_exchange(ticker: "#{OWN_TICKER_PREFIX}#{ticker}", exchange_operating_mic: mic)
      if security.new_record?
        security.offline = true
        security.offline_reason = EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON
        security.country_code = mic_country(mic)
      end
      security.name = name.presence || ticker if security.name.blank?
      security.save! if security.changed?
      security
    end

    def discard_unused_securities(security_ids)
      EtoroAccount::DataHelpers.discard_unused_securities(security_ids, accounts: [ account ])
    end

    # The resolver saves the match it found. One in another country is not
    # the line eToro holds, and left behind it would stay online, costing the
    # price provider a details request on every market-data run and a health
    # check; it goes again unless something else uses it.
    def discard_unused_match(security)
      return unless security&.previously_new_record?
      return if Holding.exists?(security_id: security.id) || Trade.exists?(security_id: security.id)

      security.destroy
    end

    # The resolver's own offline fallback carries no name, which would leave
    # the holding showing a bare ticker. A security a provider matched keeps
    # whatever the provider says about it.
    def name_offline_security(security, name)
      security.update!(name: name) if security&.offline? && security.name.blank? && name.present?
      security
    end

    def offline_security(ticker, name)
      security = Security.find_or_initialize_by_ticker_and_exchange(ticker: ticker, exchange_operating_mic: nil)
      security.name ||= name.presence || ticker
      security.offline = true if security.new_record?
      security.save! if security.changed?
      security
    end

    def debug_context
      { family: @etoro_account&.etoro_item&.family, account_provider: @etoro_account&.account_provider }
    end
end
