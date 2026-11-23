# frozen_string_literal: true

class BitcoinWalletAccount::Syncer
  RETRYABLE_ERRORS = [ BitcoinWalletAccount::Snapshot::ChangedTip, BitcoinWalletAccount::Snapshot::IncompleteMempool,
    Provider::MempoolSpace::Error ].freeze
  MAX_READ_RETRIES = 2
  MAX_LOCK_WAIT = 5.minutes
  RATE_LIMIT_WAIT = 1.minute

  # Use the injected explorer for tests or the configured history budget for
  # production. Source keys are never passed to the provider.
  def initialize(wallet, provider: nil)
    @wallet = wallet
    @provider = provider || Provider::MempoolSpace.new(max_pages: Onchain::HistoryBudget.pages)
  end

  # Keep transient read retries in the parent's tree and use the family date.
  def perform_sync(sync)
    @sync = sync
    return if wallet.account.pending_deletion? || wallet.onchain_wallet_item.scheduled_for_deletion? || sync.cancel_requested?

    Time.use_zone(Time.find_zone(wallet.family.timezone) || Time.zone) { perform }
  rescue *RETRYABLE_ERRORS => error
    raise unless retry_pending?

    queue_continuation(read_attempt: read_attempt + 1, wait: retry_wait(error))
  end

  # Coalesce concurrent readers with a session advisory lock. Provider requests
  # run outside a database transaction; disconnects and source edits invalidate
  # publication, while failed reads preserve the last complete quantity.
  def perform
    # Serialize readers without a long transaction or a wallet row lock:
    # source edits and disconnects remain available during provider requests.
    wallet.class.connection_pool.with_connection do |connection|
      key = Digest::SHA256.digest("bitcoin-wallet-sync:#{wallet.id}").unpack1("q>")
      held = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
      unless held
        if @sync
          waits = @sync.sync_stats.to_h.fetch("lock_waits", 0).to_i
          queue_continuation(lock_waits: waits + 1, wait: [ 5.seconds * 2**waits, MAX_LOCK_WAIT ].min)
        end
        return
      end

      begin
        perform_read unless read_since_requested?
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{key})")
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise if wallet.class.exists?(wallet.id) && source_signature == @source_signature
  rescue *RETRYABLE_ERRORS => error
    # A new block or a busy explorer is retried; only the last attempt fails the wallet.
    record_failure(error) unless retry_pending?
    raise
  rescue StandardError => error
    record_failure(error)
    raise
  end

  private
    attr_reader :wallet, :provider

    # Discover and read before taking the short publication lock. Recheck
    # source membership before committing the read.
    def perform_read
      @source_signature = source_signature
      tip = provider.tip_hash
      discovery = BitcoinWalletAccount::Discovery.new(wallet, provider: provider, tip: tip)
      unless discovery.perform
        wallet.with_lock do
          return unless source_signature == @source_signature

          wallet.update!(status: :discovering)
          queue_continuation(read_attempt: @sync ? read_attempt : 0)
        end
        return
      end

      begin
        anchors = wallet.bitcoin_wallet_sources.where(kind: "bip84").filter_map { |source| source.discovery["tip_hash"] }
        snapshot = BitcoinWalletAccount::Snapshot.new(wallet, provider: provider).fetch(before: tip, discovery_tips: anchors) do |observed, height|
          missing_statuses(observed, height)
        end
      rescue BitcoinWalletAccount::Snapshot::ChangedTip
        # Discovery is complete, so without reopening it the retry would skip
        # addresses it saw unused before the new block.
        wallet.with_lock { wallet.restart_discovery!(full: true) if source_signature == @source_signature }
        raise
      end

      processor = BitcoinWalletAccount::Processor.new(wallet)
      processor.prepare_prices if wallet.account_provider
      invalid_claim = false
      window = wallet.with_lock do
        if source_signature != @source_signature
          queue_continuation
          return
        end
        return if @sync&.cancel_requested?

        complete = discovery.extend_gaps!(snapshot.used_addresses, tip: snapshot.block_hash)
        wallet.bitcoin_wallet_addresses.where(address: snapshot.used_addresses.to_a, used: false).update_all(used: true)
        unless complete
          wallet.update!(status: :discovering)
          queue_continuation(read_attempt: @sync ? read_attempt : 0)
          return
        end

        unless discovery.claims_valid?
          invalid_claim = true
          next
        end

        remember_transactions(snapshot, snapshot.missing_statuses)
        attributes = { balance_sats: snapshot.balance_sats,
          history_truncated: snapshot.history_truncated, last_synced_at: Time.current, last_error: nil,
          status: wallet.account_provider ? :active : :preview }
        attributes[:baseline_block_height] = snapshot.block_height if wallet.baseline_at.nil? || wallet.needs_reconciliation?
        wallet.update!(attributes)
        # Reopen the lookahead after every read, so a deposit to a fresh
        # address is in the next quantity.
        wallet.restart_discovery!
        next unless wallet.account_provider

        if wallet.needs_reconciliation?
          wallet.bitcoin_wallet_transactions.update_all(baseline: true)
          wallet.update!(baseline_at: Time.current, needs_reconciliation: false)
        end
        processor.process(prepare_prices: false, materialize: @sync.nil?)
      end
      if invalid_claim
        raise BitcoinWalletAccount::Discovery::AddressMismatch, "The receive address does not match this BIP84 account within the selected gap limit"
      end
      queue_account_sync(window)
    end

    def queue_account_sync(window)
      return unless @sync && window && !@sync.cancel_requested?

      wallet.account.sync_later(parent_sync: @sync,
        window_start_date: [ window, @sync.window_start_date ].compact.min, window_end_date: @sync.window_end_date)
    end

    # A reader that held the lock while this sync waited may already have
    # published a complete read after this wait began; reading again only
    # repeats it. Source edits set :discovering, so they always read.
    def read_since_requested?
      return false unless @sync && @sync.sync_stats.to_h.fetch("lock_waits", 0).to_i.positive?

      wallet.reload
      !wallet.account_provider && !wallet.status_discovering? && wallet.last_synced_at.present? && wallet.last_synced_at >= @sync.created_at
    end

    # Transient reads are retried only inside a sync tree.
    def retry_pending?
      @sync.present? && read_attempt < MAX_READ_RETRIES
    end

    # A new block settles within seconds; an explorer rate limit needs minutes.
    def retry_wait(error)
      return RATE_LIMIT_WAIT * 2**read_attempt if error.is_a?(Provider::MempoolSpace::RateLimitError)

      (read_attempt + 1).seconds
    end

    def read_attempt
      @sync.sync_stats.to_h.fetch("read_attempt", 0).to_i
    end

    # Checkpoints and retries remain children so their parent cannot finish early.
    def queue_continuation(read_attempt: 0, lock_waits: 0, wait: 0.seconds)
      return if @sync&.cancel_requested?

      if @sync
        child = wallet.syncs.create!(parent: @sync, sync_stats: { read_attempt: read_attempt, lock_waits: lock_waits },
          window_start_date: @sync.window_start_date, window_end_date: @sync.window_end_date)
        SyncJob.set(wait: wait).perform_later(child)
      else
        wallet.sync_later
      end
    end

    # Describe the configured source set without including decrypted keys, so
    # changes made during provider requests can invalidate their result.
    def source_signature
      wallet.bitcoin_wallet_sources.order(:id).pluck(:id, :kind, :fingerprint, :gap_limit)
    end

    # Resolve absent pending and recently confirmed transactions explicitly.
    def missing_statuses(observed, height)
      wallet.bitcoin_wallet_transactions.where(present: true).where.not(txid: observed)
        .where("confirmed = false OR block_height >= ?", height - 6).pluck(:txid).to_h do |txid|
          [ txid, provider.get_transaction_status(txid) ]
        end
    end

    # Upsert owned net movements once per TXID, distinguish baseline history by
    # block height, and mark transactions that disappeared as no longer present.
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
          occurred_at: occurred_at)
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

    # Mark only a still-existing wallet with the same sources as failed and log
    # diagnostic classes without including public keys or provider payloads.
    def record_failure(error)
      return unless wallet.class.exists?(wallet.id)

      wallet.with_lock do
        return unless source_signature == @source_signature

        wallet.update!(status: :failed, last_error: error.class.name)
        DebugLogEntry.capture(category: "provider_sync_error", level: "error",
          message: "Bitcoin wallet could not be fully read", source: self.class.name,
          provider_key: "onchain_wallet", family: wallet.family, account: wallet.account,
          metadata: { bitcoin_wallet_account_id: wallet.id, error_class: error.class.name })
      end
    end
end
