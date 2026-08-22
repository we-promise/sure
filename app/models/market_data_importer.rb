class MarketDataImporter
  # By default, our graphs show 1M as the view, so by fetching 31 days,
  # we ensure we can always show an accurate default graph
  SNAPSHOT_DAYS = 31

  InvalidModeError = Class.new(StandardError)

  def initialize(mode: :full, clear_cache: false)
    @mode = set_mode!(mode)
    @clear_cache = clear_cache
  end

  def import_all
    import_security_prices
    import_exchange_rates
  end

  # Syncs historical security prices (and details)
  def import_security_prices
    unless Security.providers.any?
      Rails.logger.warn("No provider configured for MarketDataImporter.import_security_prices, skipping sync")
      return
    end

    # Import all securities that aren't marked as "offline" (i.e. they're available from the provider)
    Security.online.find_each do |security|
      security.import_provider_prices(
        start_date: get_first_required_price_date(security),
        end_date: end_date,
        clear_cache: clear_cache
      )

      security.import_provider_details(clear_cache: clear_cache)
    end
  end

  def import_exchange_rates
    unless ExchangeRate.provider
      Rails.logger.warn("No provider configured for MarketDataImporter.import_exchange_rates, skipping sync")
      return
    end

    required_exchange_rate_pairs.each do |pair|
      # pair is a Hash with keys :source, :target, and :start_date
      start_date = snapshot? ? default_start_date : pair[:start_date]

      ExchangeRate.import_provider_rates(
        from: pair[:source],
        to: pair[:target],
        start_date: start_date,
        end_date: end_date,
        clear_cache: clear_cache
      )
    end
  end

  private
    attr_reader :mode, :clear_cache

    def snapshot?
      mode.to_sym == :snapshot
    end

    # Builds a unique list of currency pairs with the earliest date we need
    # exchange rates for.
    #
    # Returns: Array of Hashes – [{ source:, target:, start_date: }, ...]
    def required_exchange_rate_pairs
      pair_dates = {} # { [source, target] => earliest_date }

      # 1. ENTRY-BASED PAIRS – we need rates from the first entry date
      Entry.joins(:account)
           .where.not("entries.currency = accounts.currency")
           .group("entries.currency", "accounts.currency")
           .minimum("entries.date")
           .each do |(source, target), date|
        key = [ source, target ]
        pair_dates[key] = [ pair_dates[key], date ].compact.min
      end

      # 2. ACCOUNT-BASED PAIRS – use the account's oldest entry date.
      # The earliest entry date per account is resolved in SQL to avoid loading a
      # potentially large Hash of all account IDs into Ruby memory.
      Account.joins(:family)
             .joins("LEFT JOIN (SELECT account_id, MIN(date) AS first_entry_date FROM entries GROUP BY account_id) AS entry_mins ON entry_mins.account_id = accounts.id")
             .where.not("families.currency = accounts.currency")
             .select("accounts.id, accounts.currency AS source, families.currency AS target, entry_mins.first_entry_date")
             .find_each do |account|
        earliest_entry_date = account.first_entry_date

        chosen_date = [ earliest_entry_date, default_start_date ].compact.min

        key = [ account.source, account.target ]
        pair_dates[key] = [ pair_dates[key], chosen_date ].compact.min
      end

      # 3. HOLDING → ACCOUNT – native holding currencies for balance sync
      Holding.joins(:account)
             .where.not("holdings.currency = accounts.currency")
             .group("holdings.currency", "accounts.currency")
             .minimum("holdings.date")
             .each do |(source, target), date|
        key = [ source, target ]
        pair_dates[key] = [ pair_dates[key], date ].compact.min
      end

      # 4. TRADE → HOLDING currency – cost basis conversion, scoped per account.
      #    Derive distinct currencies + earliest dates, then combine in Ruby so we
      #    never join every trade row to every holding row (nightly job blast radius).
      trade_currencies_by_account = Hash.new { |h, k| h[k] = {} }
      Trade.with_entry
           .group("entries.account_id", "trades.currency")
           .minimum("entries.date")
           .each do |(account_id, currency), date|
        trade_currencies_by_account[account_id][currency] = date
      end

      holding_currencies_by_account = Hash.new { |h, k| h[k] = {} }
      Holding.group(:account_id, :currency)
             .minimum(:date)
             .each do |(account_id, currency), date|
        holding_currencies_by_account[account_id][currency] = date
      end

      trade_currencies_by_account.each do |account_id, trade_currencies|
        holding_currencies = holding_currencies_by_account[account_id]
        next if holding_currencies.blank?

        trade_currencies.each do |trade_currency, trade_date|
          holding_currencies.each do |holding_currency, holding_date|
            next if trade_currency == holding_currency

            key = [ trade_currency, holding_currency ]
            pair_dates[key] = [ pair_dates[key], trade_date, holding_date ].compact.min
          end
        end
      end

      # 5. SECURITY PRICE → ACCOUNT – prices whose currency differs from accounts that
      #    hold/trade the security. Map security→account currencies first, then group
      #    prices by (security, currency) — no price⋈holding row explosion.
      security_account_currencies = Hash.new { |h, k| h[k] = Set.new }

      Holding.joins(:account)
             .distinct
             .pluck("holdings.security_id", "accounts.currency")
             .each do |security_id, account_currency|
        security_account_currencies[security_id] << account_currency
      end

      Trade.with_entry
           .joins("INNER JOIN accounts ON accounts.id = entries.account_id")
           .distinct
           .pluck("trades.security_id", "accounts.currency")
           .each do |security_id, account_currency|
        security_account_currencies[security_id] << account_currency
      end

      if security_account_currencies.any?
        Security::Price
          .where(security_id: security_account_currencies.keys)
          .group(:security_id, :currency)
          .minimum(:date)
          .each do |(security_id, price_currency), date|
            security_account_currencies[security_id].each do |account_currency|
              next if price_currency == account_currency

              key = [ price_currency, account_currency ]
              pair_dates[key] = [ pair_dates[key], date ].compact.min
            end
          end
      end

      # Convert to array of hashes for ease of use
      pair_dates.map do |(source, target), date|
        { source: source, target: target, start_date: date }
      end
    end

    def get_first_required_price_date(security)
      return default_start_date if snapshot?

      Trade.with_entry.where(security: security).minimum(:date) || default_start_date
    end

    # An approximation that grabs more than we likely need, but simplifies the logic
    def get_first_required_exchange_rate_date(from_currency:)
      return default_start_date if snapshot?

      Entry.where(currency: from_currency).minimum(:date) || default_start_date
    end

    def default_start_date
      SNAPSHOT_DAYS.days.ago.to_date
    end

    # Since we're querying market data from a US-based API, end date should always be today (EST)
    def end_date
      Date.current.in_time_zone("America/New_York").to_date
    end

    def set_mode!(mode)
      valid_modes = [ :full, :snapshot ]

      unless valid_modes.include?(mode.to_sym)
        raise InvalidModeError, "Invalid mode for MarketDataImporter, can only be :full or :snapshot, but was #{mode}"
      end

      mode.to_sym
    end
end
