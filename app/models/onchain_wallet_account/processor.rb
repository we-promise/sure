# frozen_string_literal: true

class OnchainWalletAccount::Processor
  def initialize(onchain_wallet_account)
    @onchain_wallet_account = onchain_wallet_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    process_holding
    process_account_balance
    process_transactions
  end

  private
    attr_reader :onchain_wallet_account

    def account
      onchain_wallet_account.current_account
    end

    def family_currency
      onchain_wallet_account.onchain_wallet_item.family.currency
    end

    def process_holding
      return if onchain_wallet_account.quantity.zero?

      security = OnchainWalletAccount::SecurityResolver.resolve(onchain_wallet_account.symbol, onchain_wallet_account.name)
      return unless security

      amount = onchain_wallet_account.current_balance.to_d
      price = amount / onchain_wallet_account.quantity

      import_adapter.import_holding(
        security: security,
        quantity: onchain_wallet_account.quantity,
        amount: amount,
        currency: family_currency,
        date: Date.current,
        price: price,
        cost_basis: nil,
        external_id: "onchain_wallet_#{onchain_wallet_account.id}_#{Date.current}",
        account_provider_id: onchain_wallet_account.account_provider&.id,
        source: "onchain_wallet",
        delete_future_holdings: false
      )
    end

    def process_account_balance
      balance = onchain_wallet_account.current_balance || 0

      Account.transaction do
        account.update!(
          cash_balance: 0,
          currency: family_currency
        )

        result = Account::CurrentBalanceManager.new(account).set_current_balance(balance)
        raise result.error unless result.success?
      end
    end

    # For each on-chain transaction, record a Buy/Sell trade when a historical
    # price is available (so cost basis + the value-over-time chart reconstruct
    # back to the acquisition date). When no price is available (e.g. no crypto
    # price provider enabled, or an unpriceable token), fall back to a
    # display-only, excluded transaction stub so the activity still appears.
    def process_transactions
      security = OnchainWalletAccount::SecurityResolver.resolve(onchain_wallet_account.symbol, onchain_wallet_account.name)

      raw_transactions.each do |tx|
        external_id = transaction_external_id(tx)
        next if external_id.blank?

        begin
          import_transaction(tx, security, external_id)
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => e
          Rails.logger.warn "OnchainWalletAccount::Processor - transaction import failed for #{external_id}: #{e.message}"
        end
      end
    end

    def import_transaction(tx, security, external_id)
      quantity = transaction_amount(tx)
      date = transaction_date(tx)
      price = quantity.zero? ? nil : historical_unit_price(security, date)

      if price&.positive?
        import_adapter.import_trade(
          security: security,
          quantity: quantity, # signed: + received (Buy), - sent (Sell)
          price: price,
          amount: quantity * price,
          currency: family_currency,
          date: date,
          external_id: external_id,
          source: "onchain_wallet",
          activity_label: quantity.positive? ? "Buy" : "Sell"
        )
      else
        import_transaction_stub(tx, external_id, date)
      end
    end

    def import_transaction_stub(tx, external_id, date)
      entry = account.entries.find_or_initialize_by(external_id: external_id, source: "onchain_wallet") do |e|
        e.entryable = Transaction.new
      end

      return if entry.persisted? && !entry.entryable.is_a?(Transaction)

      entry.assign_attributes(
        date: date,
        name: transaction_name(tx),
        amount: 0,
        currency: family_currency,
        excluded: true
      )
      entry.entryable.extra = (entry.entryable.extra || {}).deep_merge("onchain_wallet" => tx)
      entry.save!
    end

    # Per-unit market price on a date, converted to the family currency.
    def historical_unit_price(security, date)
      return nil unless security

      record = security.find_or_fetch_price(date: date)
      return nil unless record

      amount = record.price.to_d
      currency = record.currency.presence || "USD"
      return amount if currency == family_currency

      rate = ExchangeRate.find_or_fetch_rate(from: currency, to: family_currency, date: date)
      rate ? (amount * rate.rate.to_d) : nil
    end

    def raw_transactions
      payload = onchain_wallet_account.raw_transactions_payload || {}
      Array(payload["transactions"] || payload["normal_transactions"] || payload["token_transfers"])
    end

    def transaction_external_id(tx)
      hash = tx["hash"] || tx["txid"]
      return if hash.blank?

      context = [ onchain_wallet_account.chain, onchain_wallet_account.asset_kind, onchain_wallet_account.token_contract, onchain_wallet_account.symbol ].compact.join("_")
      "onchain_wallet_#{context}_#{hash}"
    end

    def transaction_date(tx)
      timestamp = tx["timeStamp"] || tx["status"]&.dig("block_time")
      timestamp.present? ? Time.zone.at(timestamp.to_i).to_date : Date.current
    end

    def transaction_name(tx)
      verb = transaction_amount(tx).negative? ? "Sent" : "Received"
      "#{verb} #{onchain_wallet_account.symbol}"
    end

    def transaction_amount(tx)
      BigDecimal(tx["onchain_amount"].to_s.presence || "0")
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end
end
