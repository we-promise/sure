class Financekit::Processor
  def initialize(item)
    @item = item
  end

  def apply_next!
    batch = nil
    @item.with_lock do
      @item.require_publisher!
      batch = @item.financekit_batches.find_by(generation: @item.generation,
        stream_id: @item.stream_id, sequence: @item.next_sequence)
      return false unless batch && batch.status == "accepted" && (!batch.retry_at || batch.retry_at <= Time.current)

      Financekit.require!(batch.predecessor_digest == @item.predecessor_digest, "predecessor_conflict", 409)
      Financekit.require!(!@item.last_captured_at || batch.captured_at >= @item.last_captured_at,
        "stale_capture", 409)
      data = JSON.parse(batch.payload)
      Financekit::Payload.validate_batch!(data, @item)
      batch.update!(status: "processing")
      counts = { "upserted" => 0, "retracted" => 0, "review_required" => 0,
        "source_only" => 0, "balances" => 0, "accounts" => 0 }
      mappings = @item.selected_accounts.includes(financekit_account_lineage: :account)
        .index_by { |mapping| mapping.source_id.downcase }
      data["events"].each { |event| apply_event!(event, mappings, batch, counts) }

      sync = @item.syncs.create!(status: "completed", completed_at: Time.current,
        sync_stats: { "financekit" => counts, "total_accounts" => mappings.size, "linked_accounts" => mappings.size })
      batch.update!(status: "applied", applied_at: Time.current, counts: counts, sync: sync,
        error_code: nil, retry_at: nil)
      @item.update!(next_sequence: batch.sequence + 1, predecessor_digest: batch.payload_digest,
        last_imported_at: batch.applied_at, last_captured_at: batch.captured_at)
    end
    Financekit::Downstream.new(batch).perform!
    true
  rescue Financekit::Error, ActiveRecord::RecordInvalid, JSON::ParserError => error
    fail_batch!(batch, error.is_a?(Financekit::Error) ? error.code : "import_validation", permanent: true)
    false
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { financekit_item_id: @item.id, batch_id: batch&.batch_id })
    fail_batch!(batch, "processing_error", permanent: false)
    false
  end

  private

    def apply_event!(event, mappings, batch, counts)
      case event.fetch("kind")
      when "account_upsert"
        import_account!(mappings.fetch(event.fetch("account").fetch("source_id").downcase), event.fetch("account"), counts)
      when "account_unavailable"
        mappings.fetch(event.fetch("source_account_id").downcase).update!(unavailable_at: Time.current)
        counts["accounts"] += 1
      when "balance_upsert"
        record = event.fetch("balance")
        import_balance!(mappings.fetch(record.fetch("source_account_id").downcase), record, counts)
      when "transaction_upsert"
        record = event.fetch("transaction")
        import_transaction!(mappings.fetch(record.fetch("source_account_id").downcase), record, batch, counts)
      when "transaction_tombstone"
        record = event.fetch("tombstone")
        retract!(mappings.fetch(record.fetch("source_account_id").downcase), record, batch, counts)
      end
    end

    def import_account!(mapping, record, counts)
      mapping.update!(name: record["display_name"], institution_name: record["institution_name"], unavailable_at: nil)
      counts["accounts"] += 1
    end

    def import_balance!(mapping, record, counts)
      observed_at = Financekit::Payload.timestamp!(record["observed_at"])
      money = record.fetch("money")
      observation = mapping.financekit_balance_observations.find_or_create_by!(source_id: record["source_id"],
        kind: record["kind"], observed_at: observed_at) do |balance|
        balance.financekit_account = mapping
        balance.amount = Financekit::Payload.money!(money)
        balance.currency = money["currency"]
        balance.direction = money["direction"]
      end
      counts["balances"] += 1 if observation.previously_new_record?
      return unless record["kind"] == "booked"

      latest = mapping.financekit_balance_observations.where(kind: "booked").maximum(:observed_at)
      return unless latest == observed_at

      account = mapping.account
      account.with_lock do
        Account::ProviderImportAdapter.new(account).update_balance(
          balance: Financekit::Mapping.balance(record, mapping.accountable_type), source: "financekit")
        account.update!(status: "active") if account.draft?
      end
    end

    def import_transaction!(mapping, record, batch, counts)
      identity = transaction_identity_for(mapping, record["source_id"])
      existed = identity.persisted?
      identity.assign_attributes(financekit_account: mapping, generation: batch.generation,
        sequence: batch.sequence, status: record["status"], raw_payload: record)
      if identity.tombstoned_at || (existed && identity.entry_id.nil? && identity.ledger_imported)
        identity.update!(review_required: true)
        create_conflict!(mapping, identity, "source_reappeared")
        counts["review_required"] += 1
        return
      end
      if %w[rejected memo].include?(record["status"])
        remove_source_only_entry!(mapping, identity, counts) if identity.entry
        identity.ledger_imported = false unless identity.review_required?
        identity.save!
        counts["source_only"] += 1
        return
      end

      account = mapping.account
      account.with_lock do
        adapter = Account::ProviderImportAdapter.new(account)
        entry = adapter.import_transaction(external_id: transaction_external_id(mapping, record.fetch("source_id")),
          amount: Financekit::Mapping.transaction_amount(record), currency: record.dig("amount", "currency"),
          date: Financekit::Mapping.ledger_date(record, mapping.ledger_timezone),
          name: record["merchant_name"].presence || record["transaction_description"].presence || "Wallet transaction",
          source: "financekit", allow_heuristic_matching: false,
          extra: { "financekit" => record.merge("pending" => %w[authorized pending].include?(record["status"])) })
        identity.update!(entry: entry, ledger_imported: true, review_required: adapter.skipped_entries.any?)
        create_conflict!(mapping, identity, "protected_entry") if identity.review_required?
        counts[identity.review_required? ? "review_required" : "upserted"] += 1
      end
    end

    def retract!(mapping, record, batch, counts)
      identity = transaction_identity_for(mapping, record["source_id"])
      identity.assign_attributes(financekit_account: mapping, generation: batch.generation, sequence: batch.sequence,
        status: "deleted", tombstoned_at: Time.current, raw_payload: nil)
      entry = identity.entry
      if entry
        Entry.transaction do
          entry.lock!
          if protected_entry?(entry) || entry.source != "financekit" || entry.account_id != mapping.account.id
            identity.review_required = true
            create_conflict!(mapping, identity, "protected_tombstone")
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
        metadata: { batch_id: batch.batch_id, source_identity_id: identity.id,
          review_required: identity.review_required })
    end

    def transaction_identity_for(mapping, source_id)
      mapping.financekit_transactions.find_or_initialize_by(source_id: source_id).tap do |identity|
        identity.financekit_account = mapping
      end
    end

    def transaction_external_id(mapping, source_id)
      "financekit:#{mapping.financekit_account_lineage_id}:#{source_id.downcase}"
    end

    def remove_source_only_entry!(mapping, identity, counts)
      entry = identity.entry
      return unless entry

      Entry.transaction do
        entry.lock!
        if protected_entry?(entry) || entry.source != "financekit" || entry.account_id != mapping.account.id
          identity.review_required = true
          create_conflict!(mapping, identity, "protected_source_update")
          counts["review_required"] += 1
        else
          entry.destroy!
          identity.entry = nil
        end
      end
    end

    def protected_entry?(entry)
      entry.protected_from_sync? || entry.transaction.transfer_id.present? || entry.reconciled_at.present? ||
        entry.split_parent? || entry.split_child? || entry.locked_attributes.present? ||
        entry.transaction.locked_attributes.present?
    end

    def create_conflict!(mapping, identity, kind)
      @item.financekit_conflicts.find_or_create_by!(financekit_transaction: identity, kind: kind, status: "open") do |conflict|
        conflict.family = @item.family
        conflict.financekit_account_lineage = mapping.financekit_account_lineage
        conflict.details = { "source_id" => identity.source_id }
      end
    end

    def fail_batch!(batch, code, permanent:)
      return unless batch

      @item.with_lock do
        batch.reload
        return unless batch.status.in?(%w[accepted processing]) && batch.generation == @item.generation

        attempts = batch.attempts + 1
        if permanent || attempts >= Financekit::MAX_ATTEMPTS
          batch.update!(attempts: attempts, status: "failed", error_code: code, retry_at: nil)
          @item.update!(status: "repair_required", repair_reason: code, credential_digest: nil)
          @item.financekit_batches.where(status: "accepted").where.not(id: batch.id)
            .update_all(status: "revoked", error_code: "stream_failed", payload: nil, updated_at: Time.current)
        else
          batch.update!(attempts: attempts, status: "accepted", error_code: code,
            retry_at: Time.current + (2**attempts).minutes)
        end
      end
      DebugLogEntry.capture(category: "provider_sync", level: "error", message: "FinanceKit import requires attention",
        source: self.class.name, provider_key: "financekit", family: @item.family,
        metadata: { batch_id: batch.batch_id, error_code: code })
    end
end
