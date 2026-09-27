# frozen_string_literal: true

class BitcoinWalletAccount::Processor
  SOURCE = "bitcoin_wallet"

  def initialize(wallet)
    @wallet = wallet
  end

  def prepare_prices
    import_prices
    currencies = wallet.security.prices.where(date: ..Date.current).distinct.pluck(:currency) - [ account.currency ]
    currencies.each do |currency|
      ExchangeRate.import_provider_rates(from: currency, to: account.currency,
        start_date: wallet.baseline_at&.to_date || Date.current, end_date: Date.current)
    end
  rescue StandardError => error
    DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
      message: "Bitcoin exchange rates could not be read", source: self.class.name,
      provider_key: "onchain_wallet", family: account.family, account: account,
      account_provider: wallet.account_provider, metadata: { error_class: error.class.name })
  end

  def process(prepare_prices: true)
    return unless wallet.account_provider && wallet.baseline_at

    self.prepare_prices if prepare_prices
    account.with_lock do
      materialize_movements
      wallet.record_reconciliation!
      BitcoinWalletAccount::Portfolio.new(wallet).materialize
    end
  end

  private
    attr_reader :wallet

    def account
      wallet.account
    end

    def import_prices
      return if wallet.security.price_data_provider.blank?
      return if wallet.security.prices.exists?(date: Date.current)

      wallet.security.import_provider_prices(start_date: wallet.baseline_at&.to_date || Date.current, end_date: Date.current)
    rescue StandardError => error
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
        message: "Bitcoin price history could not be read", source: self.class.name,
        provider_key: "onchain_wallet", family: account.family, account: account,
        account_provider: wallet.account_provider, metadata: { error_class: error.class.name })
    end

    def materialize_movements
      wallet.bitcoin_wallet_transactions.each do |row|
        external_id = "bitcoin_wallet_#{wallet.id}_#{row.txid}"
        entry = account.entries.find_by(source: SOURCE, external_id: external_id)
        if !row.present? && !row.baseline?
          entry.destroy! if entry && !entry.protected_from_sync?
          next
        end
        next if row.baseline? && row.present?

        quantity = row.baseline? ? -row.quantity : row.quantity
        date = (row.baseline? ? row.removed_at : row.occurred_at).to_date
        external_id += "_reversal" if row.baseline?
        price = BitcoinWalletAccount::Portfolio.price(wallet.security, account.currency, date) || 0
        Account::ProviderImportAdapter.new(account).import_trade(
          security: wallet.security, quantity: quantity, price: price, amount: 0,
          currency: account.currency, date: date, external_id: external_id, source: SOURCE,
          name: I18n.t("bitcoin_wallets.movements.#{quantity.positive? ? 'received' : 'sent'}",
            locale: account.family.locale, quantity: quantity.abs.to_s("F")),
          activity_label: Trade::TRANSFER_LABEL
        )
      end
    end
end
