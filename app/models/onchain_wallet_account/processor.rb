# frozen_string_literal: true

class OnchainWalletAccount::Processor
  def initialize(onchain_wallet_account)
    @onchain_wallet_account = onchain_wallet_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    process_holding
    process_account_balance
    process_transaction_stubs
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
      price = onchain_wallet_account.quantity.positive? ? amount / onchain_wallet_account.quantity : 0

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
      account.update!(
        balance: onchain_wallet_account.current_balance || 0,
        cash_balance: 0,
        currency: family_currency
      )
    end

    def process_transaction_stubs
      raw_transactions.each do |tx|
        external_id = transaction_external_id(tx)
        next if external_id.blank?

        entry = account.entries.find_or_initialize_by(external_id: external_id, source: "onchain_wallet") do |e|
          e.entryable = Transaction.new
        end

        next if entry.persisted? && !entry.entryable.is_a?(Transaction)

        entry.assign_attributes(
          date: transaction_date(tx),
          name: transaction_name(tx),
          amount: 0,
          currency: family_currency,
          excluded: true
        )
        entry.entryable.extra = (entry.entryable.extra || {}).deep_merge("onchain_wallet" => tx)
        entry.save!
      end
    rescue StandardError => e
      Rails.logger.warn "OnchainWalletAccount::Processor - transaction import failed: #{e.message}"
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
