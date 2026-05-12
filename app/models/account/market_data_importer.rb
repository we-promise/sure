class Account::MarketDataImporter
  attr_reader :account

  def initialize(account)
    @account = account
  end

  def import_all
    import_exchange_rates
    import_security_prices
  end

  def import_exchange_rates
    return unless needs_exchange_rates?
    return unless ExchangeRate.provider

    pair_dates = {}

    # 1. ENTRY-BASED PAIRS – currencies that differ from the account currency
    account.entries
           .where.not(currency: account.currency)
           .group(:currency)
           .minimum(:date)
           .each do |source_currency, date|
      key = [ source_currency, account.currency ]
      pair_dates[key] = [ pair_dates[key], date ].compact.min
    end

    # 2. ACCOUNT-BASED PAIR – convert the account currency to the family currency (if different)
    if foreign_account?
      key = [ account.currency, account.family.currency ]
      pair_dates[key] = [ pair_dates[key], account.start_date ].compact.min
    end

    pair_dates.each do |(source, target), start_date|
      ExchangeRate.import_provider_rates(
        from: source,
        to: target,
        start_date: start_date,
        end_date: Date.current
      )
    end
  end

  def import_security_prices
    return unless Security.provider

    current_security_ids = account.current_holdings.pluck(:security_id).to_set
    traded_security_ids  = account.trades.pluck(:security_id).uniq

    all_security_ids = (current_security_ids | traded_security_ids)
    return if all_security_ids.empty?

    securities = Security.online.where(id: all_security_ids).index_by(&:id)

    start_dates    = batch_first_required_price_dates(all_security_ids)
    historical_ids = traded_security_ids - current_security_ids.to_a

    # For securities no longer held, cap end_date at the last holding date so
    # all_prices_exist? stays stable and we don't call the provider every sync.
    last_holding_date = account.holdings
                               .where(security_id: historical_ids)
                               .group(:security_id)
                               .maximum(:date)

    # import_market_data runs before materialize_balances in Account::Syncer, so
    # current_holdings can reflect a stale pre-trade snapshot. If a historical
    # security has a trade newer than its last holding date the position was
    # reopened this sync; fetch prices through today so the forthcoming
    # materialization has a price available.
    latest_trade_date = account.trades
                               .where(security_id: historical_ids)
                               .group(:security_id)
                               .maximum("entries.date")

    all_security_ids.each do |security_id|
      security = securities[security_id]
      next unless security

      end_date = if current_security_ids.include?(security_id)
        Date.current
      else
        holding_date = last_holding_date[security_id]
        trade_date   = latest_trade_date[security_id]
        reopened     = trade_date && holding_date && trade_date > holding_date
        reopened ? Date.current : (holding_date || Date.current)
      end

      security.import_provider_prices(start_date: start_dates[security_id], end_date: end_date)
      security.import_provider_details
    end
  end

  private
    # Replaces 2-queries-per-security with 3 queries total.
    def batch_first_required_price_dates(security_ids)
      # account.trades is a has_many :through :entries, so entries is already joined
      trade_start_dates = account.trades.group(:security_id).minimum("entries.date")

      provider_holding_security_ids = account.holdings
                                             .where(security_id: security_ids)
                                             .where.not(account_provider_id: nil)
                                             .pluck(:security_id)
                                             .to_set

      account_start_date = account.start_date

      security_ids.each_with_object({}) do |security_id, hash|
        trade_date   = trade_start_dates[security_id]
        holding_date = provider_holding_security_ids.include?(security_id) ? account_start_date : nil
        hash[security_id] = [ trade_date, holding_date ].compact.min || account_start_date
      end
    end

    def needs_exchange_rates?
      has_multi_currency_entries? || foreign_account?
    end

    def has_multi_currency_entries?
      account.entries.where.not(currency: account.currency).exists?
    end

    def foreign_account?
      return false if account.family.nil?
      account.currency != account.family.currency
    end
end
