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

    # A security may be shared by accounts with different holding periods. Merge
    # their required ranges before calling the provider once per security.
    windows = required_security_price_windows

    Security.online.where(id: windows.keys).find_each do |security|
      window = windows.fetch(security.id)
      next if snapshot? && window.end_date < default_start_date

      security.import_provider_prices(
        start_date: snapshot? ? [ window.start_date, default_start_date ].max : window.start_date,
        end_date: window.end_date,
        clear_cache: clear_cache
      )
    end

    # Details are metadata rather than prices, and import_provider_details skips
    # the provider once a security has them, so every online security keeps them.
    Security.online.find_each do |security|
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

    def required_security_price_windows
      windows = {}
      # Account status does not close a position; retained holdings still count.
      accounts_with_securities = Account.where(id: Holding.select(:account_id))
        .or(Account.where(id: Entry.where(entryable_type: "Trade").select(:account_id)))

      accounts_with_securities.find_each do |account|
        Security::Price::ImportWindows.new(account, today: end_date).to_h.each do |security_id, window|
          previous = windows[security_id]
          windows[security_id] = if previous
            Security::Price::ImportWindows::Window.new(
              start_date: [ previous.start_date, window.start_date ].min,
              end_date: [ previous.end_date, window.end_date ].max
            )
          else
            window
          end
        end
      end

      windows
    end

    def snapshot?
      mode.to_sym == :snapshot
    end

    # Builds a unique list of currency pairs with the earliest date we need
    # exchange rates for.
    #
    # Returns: Array of Hashes – [{ source:, target:, start_date: }, ...]
    def required_exchange_rate_pairs
      pair_dates = {} # { [source, target] => earliest_date }

      # 1. ENTRY-BASED PAIRS – we need rates from the first entry date.
      # Each entry currency is also fetched against the normalized family currency:
      # transfer matching derives cross rates through it and does not chain
      # entry -> account -> family rates.
      Entry.joins(account: :family)
           .where.not("entries.currency = accounts.currency")
           .group("entries.currency", "accounts.currency", "families.currency")
           .minimum("entries.date")
           .each do |(source, account_currency, family_currency), date|
        family_target = Family.normalize_currency_code(family_currency) || "USD"

        [ account_currency, family_target ].uniq.each do |target|
          next if target == source

          key = [ source, target ]
          pair_dates[key] = [ pair_dates[key], date ].compact.min
        end
      end

      # 2. ACCOUNT-BASED PAIRS – use the account's oldest entry date.
      # The earliest entry date per account is resolved in SQL to avoid loading a
      # potentially large Hash of all account IDs into Ruby memory.
      # The target is the family's normalized primary currency (USD when the column
      # is blank or NULL), the same currency transfer matching converts through.
      # IS DISTINCT FROM keeps NULL-currency families; the exact check happens in Ruby.
      Account.joins(:family)
             .joins("LEFT JOIN (SELECT account_id, MIN(date) AS first_entry_date FROM entries GROUP BY account_id) AS entry_mins ON entry_mins.account_id = accounts.id")
             .where("families.currency IS DISTINCT FROM accounts.currency")
             .select("accounts.id, accounts.currency AS source, families.currency AS family_currency, entry_mins.first_entry_date")
             .find_each do |account|
        target = Family.normalize_currency_code(account.family_currency) || "USD"
        next if target == account.source

        earliest_entry_date = account.first_entry_date

        chosen_date = [ earliest_entry_date, default_start_date ].compact.min

        key = [ account.source, target ]
        pair_dates[key] = [ pair_dates[key], chosen_date ].compact.min
      end

      # Convert to array of hashes for ease of use
      pair_dates.map do |(source, target), date|
        { source: source, target: target, start_date: date }
      end
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
