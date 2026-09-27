# frozen_string_literal: true

class BitcoinWalletAccount::Syncer
  def initialize(wallet, provider: nil)
    @wallet = wallet
    @provider = provider || Provider::MempoolSpace.new(max_pages: Onchain::HistoryBudget.pages)
  end

  def perform
    # Serialize readers without a long transaction or a wallet row lock:
    # source edits and disconnects remain available during provider requests.
    wallet.class.connection_pool.with_connection do |connection|
      key = Digest::SHA256.digest("bitcoin-wallet-sync:#{wallet.id}").unpack1("q>")
      held = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
      return unless held

      begin
        perform_read
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{key})")
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise if wallet.class.exists?(wallet.id) && source_signature == @source_signature
  rescue StandardError => error
    record_failure(error)
    raise
  end

  private
    attr_reader :wallet, :provider

    def perform_read
      @source_signature = source_signature
      complete = BitcoinWalletAccount::Discovery.new(wallet, provider: provider).perform
      unless complete
        wallet.with_lock do
          return unless source_signature == @source_signature

          wallet.update!(status: :discovering)
          BitcoinWalletSyncJob.perform_later(wallet)
        end
        return
      end

      snapshot = BitcoinWalletAccount::Snapshot.new(wallet, provider: provider).fetch
      statuses = missing_statuses(snapshot)
      processor = BitcoinWalletAccount::Processor.new(wallet)
      processor.prepare_prices if wallet.account_provider

      wallet.with_lock do
        return unless source_signature == @source_signature

        wallet.bitcoin_wallet_addresses.where(address: snapshot.used_addresses.to_a, used: false).update_all(used: true)
        remember_transactions(snapshot, statuses)
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
          processor.process(prepare_prices: false)
          wallet.restart_discovery!
        end
      end
    end

    def source_signature
      wallet.bitcoin_wallet_sources.order(:id).pluck(:id, :kind, :fingerprint, :gap_limit)
    end

    def missing_statuses(snapshot)
      observed = snapshot.transactions.map { |tx| tx.fetch("txid") }
      wallet.bitcoin_wallet_transactions.where(present: true).where.not(txid: observed)
        .where("confirmed = false OR block_height >= ?", snapshot.block_height - 6).pluck(:txid).to_h do |txid|
          status = provider.get_transaction_status(txid)
          if status && status["confirmed"] && status["block_height"].to_i > snapshot.block_height
            raise BitcoinWalletAccount::Snapshot::ChangedTip, "A transaction confirmed after the wallet read"
          end
          [ txid, status ]
        end
    end

    def remember_transactions(snapshot, statuses)
      addresses = wallet.bitcoin_wallet_addresses.pluck(:address).to_set
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

      statuses.each do |txid, status|
        row = wallet.bitcoin_wallet_transactions.find_by(txid: txid)
        next unless row

        if status && status["confirmed"]
          row.update!(confirmed: true, block_height: status["block_height"])
        else
          row.update!(present: false, removed_at: Time.current)
        end
      end
    end

    def record_failure(error)
      return unless wallet.class.exists?(wallet.id)

      wallet.with_lock do
        return unless source_signature == @source_signature

        wallet.update!(status: :failed, last_error: error.class.name)
        DebugLogEntry.capture(category: "provider_sync_error", level: "error",
          message: "Bitcoin wallet could not be fully read", source: self.class.name,
          provider_key: "onchain_wallet", family: wallet.family, account: wallet.account,
          account_provider: wallet.account_provider,
          metadata: { bitcoin_wallet_account_id: wallet.id, error_class: error.class.name })
      end
    end
end
