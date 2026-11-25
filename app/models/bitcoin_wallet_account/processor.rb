# frozen_string_literal: true

class BitcoinWalletAccount::Processor
  SOURCE = "bitcoin_wallet"

  # Bind a publisher to its wallet and existing account without a separate portfolio.
  def initialize(wallet)
    @wallet = wallet
  end

  # Provider I/O happens before taking accounting locks.
  def prepare_prices
    Account::MarketDataImporter.new(account).import_all
    if wallet.security.price_data_provider.present? && !wallet.security.prices.exists?(date: Date.current)
      wallet.security.import_provider_prices(start_date: wallet.baseline_at&.to_date || Date.current, end_date: Date.current)
    end
    currencies = wallet.security.prices.where(date: ..Date.current).distinct.pluck(:currency) - [ account.currency ]
    currencies.each do |currency|
      ExchangeRate.import_provider_rates(from: currency, to: account.currency,
        start_date: wallet.baseline_at&.to_date || Date.current, end_date: Date.current)
    end
  rescue StandardError => error
    DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
      message: "Bitcoin valuation data could not be refreshed", source: self.class.name,
      provider_key: "onchain_wallet", family: account.family, account: account,
      account_provider: wallet.account_provider, metadata: { error_class: error.class.name })
  end

  # Use shared quote precedence and stored FX without HTTP inside publication.
  def price_on(date)
    # A single exact-date market quote outranks the journal and holdings.
    quotes = wallet.security.prices.where(date: date).limit(2).pluck(:currency, :price)
    if quotes.one?
      currency, price = quotes.first
      return price if currency == account.currency

      rate = ExchangeRate.find_stored_rate(from: currency, to: account.currency, date: date)
      return rate && price * rate.rate
    end

    Holding::PortfolioCache.new(account, security_ids: [ wallet.security_id ],
      use_holdings: true, carry_forward_prices: true, stored_rates_only: true).get_price(wallet.security_id, date)&.price
  end

  # Publish only BTC. Shared materializers own cash, other assets and history.
  def process(prepare_prices: true, materialize: true, movements_changed: true)
    return unless wallet.account_provider && wallet.baseline_at

    self.prepare_prices if prepare_prices
    price = price_on(Date.current)
    unless price
      wallet.update!(last_error: "MissingPrice")
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
        message: "Bitcoin quantity read successfully, but valuation is unavailable", source: self.class.name,
        provider_key: "onchain_wallet", family: wallet.family, account: account, account_provider: wallet.account_provider)
      return
    end

    wallet.with_lock do
      return unless wallet.account_provider && wallet.baseline_at

      account.with_lock do
        date = Date.current
        external_id = "bitcoin_wallet_#{wallet.id}_#{date.iso8601}"
        amount = wallet.quantity * price
        if !movements_changed && !wallet.pending_materialization_start_date &&
            wallet.account_provider.holdings.exists?(external_id: external_id, date: date, currency: account.currency,
              qty: wallet.quantity, price: price, amount: amount)
          return
        end

        establish_cash_baseline if wallet.initial_valuation_pending?
        earliest_movement = materialize_movements
        wallet.record_reconciliation!(price: price)
        Account::ProviderImportAdapter.new(account).import_holding(security: wallet.security,
          quantity: wallet.quantity, price: price, amount: amount,
          currency: account.currency, date: date, source: SOURCE,
          external_id: external_id, account_provider_id: wallet.account_provider.id)
        account.holdings.reset
        window = [ wallet.pending_materialization_start_date, earliest_movement ].compact.min
        wallet.update!(last_error: nil, pending_materialization_start_date: window)
        wallet.materialize_balances!(window_start_date: window) if materialize
        window
      end
    end
  end

  private
    attr_reader :wallet

    # Use the existing account as the tenancy and accounting boundary.
    def account
      wallet.account
    end

    def establish_cash_baseline
      account.holdings.where(security: wallet.security, date: ..Date.current).order(date: :desc).first&.reconcile_trade_quantity!
      account.create_cash_anchor!(cash: (0 if account.typed_balance_only?)).update!(source: SOURCE)
    end

    # Reconcile source-scoped transfers and reversals, returning the earliest changed date.
    def materialize_movements
      window = Date.current
      rows = account.entries.where(source: SOURCE).includes(:entryable).index_by(&:external_id)
      prices = Holding::PortfolioCache.new(account, security_ids: [ wallet.security_id ], use_holdings: true,
        carry_forward_prices: true, stored_rates_only: true)
      prices_by_date = {}
      wallet.bitcoin_wallet_transactions.find_each do |row|
        external_id = "bitcoin_wallet_#{wallet.id}_#{row.txid}"
        external_id += "_reversal" if row.baseline?
        entry = rows[external_id]
        if (row.present? && row.baseline?) || (!row.present? && !row.baseline?)
          if entry && !entry.protected_from_sync?
            window = [ window, entry.date ].min
            entry.entryable.provider_importing = true
            entry.destroy!
          end
          next
        end
        next if entry&.protected_from_sync?

        quantity = row.baseline? ? -row.quantity : row.quantity
        date = (row.baseline? ? row.removed_at : row.occurred_at).to_date
        price = prices_by_date.fetch(date) { prices_by_date[date] = prices.get_price(wallet.security_id, date)&.price }
        next unless price
        extra = { "bitcoin_wallet" => { "pending" => !row.confirmed?, "txid" => row.txid }, "balance_adjustment" => row.baseline? }
        next if entry && entry.date == date && entry.entryable.qty == quantity && entry.entryable.price == price &&
          entry.entryable.extra.slice(*extra.keys) == extra

        window = [ window, date, entry&.date ].compact.min
        Account::ProviderImportAdapter.new(account).import_trade(
          security: wallet.security, quantity: quantity, price: price, amount: 0,
          currency: account.currency, date: date, external_id: external_id, source: SOURCE,
          name: I18n.t("bitcoin_wallet.movements.#{quantity.positive? ? 'received' : 'sent'}",
            locale: account.family.locale, quantity: quantity.abs.to_s("F")), activity_label: Trade::TRANSFER_LABEL,
          extra: extra)
      end
      window
    end
end
