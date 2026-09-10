class Financekit::Processor
  def initialize(item)
    @item = item
  end

  def apply_next!
    batch = nil
    @item.with_lock do
      @item.require_writer!
      batch = @item.financekit_batches.find_by(generation: @item.generation, sequence: @item.next_sequence)
      return false unless batch && batch.status == "accepted" && (!batch.retry_at || batch.retry_at <= Time.current)
      Financekit.require!(batch.previous_digest == @item.previous_digest, "predecessor_conflict", 409)
      Financekit.require!(!@item.last_captured_at || batch.captured_at >= @item.last_captured_at, "stale_capture", 409)
      claims = Financekit::Crypto.verify(batch.envelope, @item)
      payload = Financekit::Payload.validate!(Financekit::Crypto.decrypt(claims["ciphertext"]), @item)
      batch.update!(status: "processing")
      counts = { "upserted" => 0, "retracted" => 0, "review_required" => 0, "source_only" => 0 }
      mappings = @item.selected_accounts.includes(:account).index_by(&:source_id)
      payload["accounts"].each { |record| import_balance!(mappings.fetch(record["source_id"]), record) }
      payload["transactions"].each { |record| import_transaction!(mappings.fetch(record["account_id"]), record, batch, counts) }
      payload["tombstones"].each { |record| retract!(mappings.fetch(record["account_id"]), record, batch, counts) }
      sync = @item.syncs.create!(status: "completed", completed_at: Time.current,
        sync_stats: { "financekit" => counts, "total_accounts" => mappings.size, "linked_accounts" => mappings.size })
      batch.update!(status: "applied", applied_at: Time.current, counts: counts, sync: sync, error_code: nil)
      @item.update!(next_sequence: batch.sequence + 1, previous_digest: batch.digest,
        last_imported_at: batch.applied_at, last_captured_at: batch.captured_at)
    end
    true
  rescue Financekit::Error, ActiveRecord::RecordInvalid => error
    fail_batch!(batch, error.is_a?(Financekit::Error) ? error.code : "import_validation", permanent: true)
    false
  rescue StandardError
    # Never include exception messages: validation/SQL errors can contain money,
    # merchant names and decrypted input. The same bounded code is used in health.
    fail_batch!(batch, "processing_error", permanent: false)
    false
  end

  private

    def import_balance!(source, record)
      observed = Financekit::Payload.timestamp!(record["observed_at"])
      Financekit.require!(!source.observed_at || observed >= source.observed_at, "stale_balance", 409)
      source.update!(record.slice("booked_balance", "available_balance").merge("observed_at" => observed))
      return unless record["booked_balance"]

      balance = Financekit::Mapping.balance(record["booked_balance"], source.accountable_type)
      source.account.with_lock do
        Account::ProviderImportAdapter.new(source.account).update_balance(balance: balance, source: "financekit")
        source.account.update!(status: "active") if source.account.draft?
      end
    end

    def import_transaction!(source, record, batch, counts)
      identity = source.financekit_transactions.find_or_initialize_by(source_id: record["source_id"])
      existed = identity.persisted?
      identity.assign_attributes(generation: batch.generation, sequence: batch.sequence, status: record["status"], raw_payload: record)
      # An explicit removal (or a user deleting the ledger entry) is durable. A
      # subsequent upsert cannot resurrect it without human reconciliation.
      if identity.tombstoned_at || (existed && identity.entry_id.nil? && identity.ledger_imported)
        identity.update!(review_required: true)
        counts["review_required"] += 1
        return
      end
      if %w[rejected memo].include?(record["status"])
        identity.save!
        retract!(source, record, batch, counts) if identity.entry
        counts["source_only"] += 1
        return
      end
      account = source.account
      account.with_lock do
        adapter = Account::ProviderImportAdapter.new(account)
        entry = adapter.import_transaction(external_id: "#{source.id}:#{record.fetch('source_id')}",
          amount: Financekit::Mapping.transaction_amount(record), currency: record.fetch("currency"),
          date: Financekit::Mapping.ledger_date(record, source.ledger_timezone),
          name: record["merchant"].presence || record["description"].presence || "Wallet transaction",
          source: "financekit", allow_heuristic_matching: false,
          extra: { "financekit" => record.merge("pending" => %w[authorized pending].include?(record["status"])) })
        identity.update!(entry: entry, ledger_imported: true, review_required: adapter.skipped_entries.any?)
        counts[identity.review_required ? "review_required" : "upserted"] += 1
      end
    end

    def retract!(source, record, batch, counts)
      identity = source.financekit_transactions.find_or_initialize_by(source_id: record["source_id"])
      identity.assign_attributes(generation: batch.generation, sequence: batch.sequence,
        status: "deleted", tombstoned_at: Time.current, raw_payload: nil)
      entry = identity.entry
      if entry
        # Entry#transaction is the delegated transaction record, so its instance
        # with_lock cannot open an ActiveRecord transaction. Use the class API.
        Entry.transaction do
          entry.lock!
          protected = entry.protected_from_sync? || entry.transaction.transfer_id.present? || entry.reconciled_at.present? ||
            entry.split_parent? || entry.split_child? || entry.locked_attributes.present? || entry.transaction.locked_attributes.present?
          if protected || entry.source != "financekit" || entry.account_id != source.account.id
            identity.review_required = true
            counts["review_required"] += 1
          else
            entry.destroy!
            identity.entry = nil
            counts["retracted"] += 1
          end
        end
      end
      identity.save!
      DebugLogEntry.capture(category: "provider_sync", level: "info", message: "FinanceKit tombstone processed",
        source: self.class.name, provider_key: "financekit", family: @item.family,
        metadata: { batch_id: batch.batch_id, source_identity_id: identity.id, review_required: identity.review_required })
    end

    def fail_batch!(batch, code, permanent:)
      return unless batch
      @item.with_lock do
        batch.reload
        return unless batch.status == "accepted" && batch.generation == @item.generation && @item.status == "active"
        attempts = batch.attempts + 1
        batch.update!(attempts: attempts, status: permanent || attempts >= Financekit::MAX_ATTEMPTS ? "failed" : "accepted",
          error_code: code, retry_at: Time.current + (2**attempts).minutes)
      end
      DebugLogEntry.capture(category: "provider_sync", level: "error", message: "FinanceKit import requires attention",
        source: self.class.name, provider_key: "financekit", family: @item.family,
        metadata: { batch_id: batch.batch_id, error_code: code })
    end
end
