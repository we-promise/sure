# frozen_string_literal: true

class BitcoinWalletAccount::Syncer
  def initialize(wallet, provider: nil)
    @wallet = wallet
    @provider = provider || Provider::MempoolSpace.new(max_pages: Onchain::HistoryBudget.pages)
  end

  def perform
    wallet.with_lock do
      return if wallet.destroyed?
      unless BitcoinWalletAccount::Discovery.new(wallet, provider: provider).perform
        wallet.update!(status: :discovering)
        BitcoinWalletSyncJob.perform_later(wallet)
        return
      end
      snapshot = BitcoinWalletAccount::Snapshot.new(wallet, provider: provider).fetch
      remember_transactions(snapshot)
      attributes = { balance_sats: snapshot.balance_sats,
        history_truncated: snapshot.history_truncated, last_synced_at: Time.current, last_error: nil,
        status: wallet.account_provider ? :active : :preview }
      attributes[:baseline_block_height] = snapshot.block_height if wallet.baseline_at.nil? || wallet.needs_reconciliation?
      wallet.update!(attributes)
      if wallet.account_provider
        if wallet.needs_reconciliation?
          wallet.bitcoin_wallet_transactions.update_all(baseline: true)
          wallet.update!(baseline_at: Time.current, baseline_sats: snapshot.balance_sats,
            baseline_cash_balance: wallet.account.cash_balance, needs_reconciliation: false)
          wallet.record_reconciliation!
        end
        BitcoinWalletAccount::Processor.new(wallet).process
        wallet.restart_discovery!
      end
    end
  rescue StandardError => error
    wallet.update!(status: :failed, last_error: error.class.name)
    DebugLogEntry.capture(category: "provider_sync_error", level: "error",
      message: "Bitcoin wallet could not be fully read", source: self.class.name,
      provider_key: "onchain_wallet", family: wallet.onchain_wallet_item.family,
      account: wallet.account, account_provider: wallet.account_provider,
      metadata: { bitcoin_wallet_account_id: wallet.id, error_class: error.class.name })
    raise
  end

  private
    attr_reader :wallet, :provider

    def remember_transactions(snapshot)
      addresses = wallet.bitcoin_wallet_addresses.pluck(:address).to_set
      observed_ids = snapshot.transactions.map { |tx| tx.fetch("txid") }.to_set
      snapshot.transactions.each do |transaction|
        txid = transaction.fetch("txid")
        amount = BitcoinWalletAccount::Snapshot.net_sats(transaction, addresses)
        next if amount.zero?

        status = transaction.fetch("status")
        row = wallet.bitcoin_wallet_transactions.find_or_initialize_by(txid: txid)
        occurred_at = row.occurred_at || (status["block_time"] ? Time.zone.at(status["block_time"]) : Time.current)
        old = wallet.baseline_at && status["confirmed"] && status["block_height"].to_i <= wallet.baseline_block_height.to_i
        occurred_at = Time.current if wallet.baseline_at && !old && occurred_at < wallet.baseline_at
        row.assign_attributes(amount_sats: amount, confirmed: status.fetch("confirmed"),
          present: true, removed_at: nil, block_height: status["block_height"],
          occurred_at: occurred_at, raw_payload: transaction)
        row.baseline = true if old || wallet.baseline_at.nil?
        row.save! if row.changed?
      end

      # An omitted page is never proof that a transfer disappeared. Previously
      # seen pending and recent confirmed transactions are verified explicitly.
      wallet.bitcoin_wallet_transactions.where(present: true)
        .where("confirmed = false OR block_height >= ?", snapshot.block_height - 6).find_each do |row|
          next if observed_ids.include?(row.txid)

          status = provider.get_transaction_status(row.txid)
          if status && status["confirmed"]
            raise BitcoinWalletAccount::Snapshot::ChangedTip, "A transaction confirmed after the wallet read" if status["block_height"].to_i > snapshot.block_height

            row.update!(confirmed: status.fetch("confirmed"), block_height: status["block_height"])
          else
            row.update!(present: false, removed_at: Time.current)
          end
        end
    end
end
