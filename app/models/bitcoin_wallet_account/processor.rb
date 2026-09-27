# frozen_string_literal: true

class BitcoinWalletAccount::Processor
  SOURCE = "bitcoin_wallet"

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
    Holding::PortfolioCache.new(account, security_ids: [ wallet.security_id ],
      use_holdings: true, carry_forward_prices: true, stored_rates_only: true).get_price(wallet.security_id, date)&.price
  end

  # Publish only BTC. Shared materializers own cash, other assets and history.
  def process(prepare_prices: true, materialize: true)
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

    window = [ Date.current, account.materialization_window ].compact.min
    account.with_lock do
      window = [ window, materialize_movements ].min
      wallet.record_reconciliation!
      Account::ProviderImportAdapter.new(account).import_holding(security: wallet.security,
        quantity: wallet.quantity, price: price, amount: wallet.quantity * price,
        currency: account.currency, date: Date.current, source: SOURCE,
        external_id: "bitcoin_wallet_#{wallet.id}_#{Date.current.iso8601}", account_provider_id: wallet.account_provider.id)
      account.holdings.reset
      wallet.update!(last_error: nil) if wallet.last_error.present?
    end
    if materialize
      Balance::Materializer.new(account, strategy: account.balance_calculation_strategy,
        window_start_date: window).materialize_balances
    end
    window
  end

  private
    attr_reader :wallet

    def account
      wallet.account
    end

    def materialize_movements
      window = Date.current
      rows = account.entries.where(source: SOURCE).includes(:entryable).index_by(&:external_id)
      prices = Holding::PortfolioCache.new(account, security_ids: [ wallet.security_id ], use_holdings: true,
        carry_forward_prices: true, stored_rates_only: true)
      wallet.bitcoin_wallet_transactions.find_each do |row|
        external_id = "bitcoin_wallet_#{wallet.id}_#{row.txid}"
        external_id += "_reversal" if row.baseline?
        entry = rows[external_id]
        if (row.present? && row.baseline?) || (!row.present? && !row.baseline?)
          if entry && !entry.protected_from_sync?
            window = [ window, entry.date ].min
            entry.destroy!
          end
          next
        end
        next if entry&.protected_from_sync?

        quantity = row.baseline? ? -row.quantity : row.quantity
        date = (row.baseline? ? row.removed_at : row.occurred_at).to_date
        price = prices.get_price(wallet.security_id, date)&.price
        next unless price
        extra = { "bitcoin_wallet" => { "pending" => !row.confirmed?, "txid" => row.txid }, "balance_adjustment" => row.baseline? }
        next if entry && entry.date == date && entry.entryable.qty == quantity && entry.entryable.price == price && entry.entryable.extra == extra

        window = [ window, date, entry&.date ].compact.min
        imported = Account::ProviderImportAdapter.new(account).import_trade(
          security: wallet.security, quantity: quantity, price: price, amount: 0,
          currency: account.currency, date: date, external_id: external_id, source: SOURCE,
          name: I18n.t("bitcoin_wallets.movements.#{quantity.positive? ? 'received' : 'sent'}",
            locale: account.family.locale, quantity: quantity.abs.to_s("F")), activity_label: Trade::TRANSFER_LABEL)
        imported.entryable.update!(extra: extra)
      end
      window
    end
end
