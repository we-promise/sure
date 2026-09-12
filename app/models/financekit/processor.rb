class Financekit::Processor
  def initialize(item)
    @item = item
  end

  def apply!(input)
    batch = @item.with_lock do
      @item.require_writer!
      payload = Financekit::Payload.validate!(input, @item)
      captured_at = Financekit::Payload.timestamp!(payload["captured_at"])
      Financekit.require!(!@item.last_captured_at || captured_at >= @item.last_captured_at, "stale_capture", 409)

      batch = @item.financekit_batches.create!(batch_id: SecureRandom.uuid, captured_at: captured_at, status: "processing")
      counts = { "upserted" => 0, "retracted" => 0, "review_required" => 0, "source_only" => 0 }
      mappings = @item.selected_accounts.includes(:account).index_by(&:source_id)

      payload["accounts"].each { |record| import_balance!(mappings.fetch(record["source_id"]), record) }
      payload["transactions"].each { |record| import_transaction!(mappings.fetch(record["account_id"]), record, batch, counts) }
      payload["tombstones"].each { |record| retract!(mappings.fetch(record["account_id"]), record, batch, counts) }

      sync = @item.syncs.create!(status: "completed", completed_at: Time.current,
        sync_stats: { "financekit" => counts, "total_accounts" => mappings.size, "linked_accounts" => mappings.size })
      batch.update!(status: "applied", applied_at: Time.current, counts: counts, sync: sync, error_code: nil)
      @item.update!(last_device_contact_at: Time.current, last_imported_at: batch.applied_at, last_captured_at: batch.captured_at)

      batch
    end
    schedule_downstream
    batch
  rescue Financekit::Error
    raise
  rescue ActiveRecord::RecordInvalid
    raise Financekit::Error.new("import_validation")
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
      identity.assign_attributes(status: record["status"], raw_payload: record)
      # An explicit removal (or a user deleting the ledger entry) is durable. A
      # subsequent upsert cannot resurrect it without human reconciliation.
      if identity.tombstoned_at || (existed && identity.entry_id.nil? && identity.ledger_imported)
        identity.update!(review_required: true)
        counts["review_required"] += 1
        return
      end
      if %w[rejected memo].include?(record["status"])
        remove_source_only_entry!(source, identity, counts) if identity.entry
        identity.ledger_imported = false unless identity.review_required?
        identity.save!
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
      identity.assign_attributes(status: "deleted", tombstoned_at: Time.current, raw_payload: nil)
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

    def remove_source_only_entry!(source, identity, counts)
      entry = identity.entry
      return unless entry

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
        end
      end
    end

    def schedule_downstream
      @item.selected_accounts.includes(:account).find_each { |source| source.account&.sync_later }
      @item.family.auto_match_transfers!
      @item.family.rules.where(active: true).find_each(&:apply_later)
    rescue StandardError
      DebugLogEntry.capture(category: "provider_sync", level: "error",
        message: "FinanceKit foreground sync downstream scheduling failed",
        source: self.class.name, provider_key: "financekit", family: @item.family)
    end
end
