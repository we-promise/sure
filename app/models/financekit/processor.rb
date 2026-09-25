class Financekit::Processor
  def initialize(item)
    @item = item
  end

  # Returns every part of the capture it applied, so the caller can complete
  # them together. Returning only the last chunk left the earlier ones without
  # downstream work, and the recovery sweep then repeated the fan-out for them.
  def apply_next!
    batch = nil
    applied = nil
    @item.with_lock do
      @item.require_publisher!
      batch = @item.financekit_batches.find_by(generation: @item.generation,
        stream_id: @item.stream_id, sequence: @item.next_sequence)
      return false unless batch && batch.status == "accepted" && (!batch.retry_at || batch.retry_at <= Time.current)
      capture = @item.financekit_batches.where(generation: @item.generation, capture_id: batch.capture_id).order(:chunk_index).to_a
      return false unless capture.size == batch.chunk_count && capture.map(&:chunk_index) == (0...batch.chunk_count).to_a &&
        capture.all? { |part| part.status == "accepted" && (!part.retry_at || part.retry_at <= Time.current) }

      Financekit.require!(!@item.last_captured_at || batch.captured_at >= @item.last_captured_at,
        "stale_capture", 409)
      counts = { "upserted" => 0, "retracted" => 0, "review_required" => 0,
        "source_only" => 0, "settled" => 0, "balances" => 0, "accounts" => 0 }
      mappings = @item.selected_accounts.includes(financekit_account_lineage: :account)
        .index_by { |mapping| mapping.source_id.downcase }
      predecessor_digest = @item.predecessor_digest
      capture.each do |part|
        batch = part
        Financekit.require!(part.predecessor_digest == predecessor_digest, "predecessor_conflict", 409)
        data = JSON.parse(part.payload)
        Financekit::Payload.validate_batch!(data, @item)
        part.update!(status: "processing")
        data["events"].each { |event| apply_event!(event, mappings, part, counts) }
        predecessor_digest = part.payload_digest
      end
      applied_at = Time.current
      sync = @item.syncs.create!(status: "completed", completed_at: applied_at,
        sync_stats: { "financekit" => counts, "total_accounts" => mappings.size, "linked_accounts" => mappings.size })
      capture.each { |part| part.update!(status: "applied", applied_at: applied_at, counts: counts, sync: sync,
        error_code: nil, retry_at: nil) }
      last = capture.last
      @item.update!(next_sequence: last.sequence + 1, predecessor_digest: last.payload_digest,
        last_imported_at: applied_at, last_captured_at: last.captured_at)
      batch = last
      applied = capture
    end
    Financekit::Diagnostics.capture(item: @item, batch: batch, source: self.class.name,
      message: "FinanceKit capture imported", event: "capture_imported", counts: batch.counts, sync_id: batch.sync_id)
    # Downstream work belongs to the caller: it completes every part of the
    # capture together, and a drain pays for the family fan-out once rather
    # than once per capture.
    applied
  rescue ActiveRecord::RecordInvalid => error
    # Retryable. RecordInvalid covers ordinary races — a concurrent balance
    # observation or conflict insert, an entry validation a later attempt
    # clears — as well as genuinely poisoned input. Fencing on the first
    # occurrence sends the publisher to repair_required and clears the upload
    # credential, which only a foreground, OAuth-authenticated repair can
    # reissue: no background wake can recover from it. Let the bounded
    # MAX_ATTEMPTS backoff decide instead. A transient race clears itself; a
    # persistent one still ends in the same fenced state, just not on a single
    # unlucky save.
    Rails.error.report(error, handled: true,
      context: { financekit_item_id: @item.id, batch_id: batch&.batch_id })
    fail_batch!(batch, "import_validation", permanent: false, error_class: error.class.name)
    false
  rescue Financekit::Error, JSON::ParserError => error
    # Not retryable. The stored payload is immutable, so a protocol violation
    # or bytes that no longer parse give every later attempt the same input.
    fail_batch!(batch, error.is_a?(Financekit::Error) ? error.code : "import_validation", permanent: true, error_class: error.class.name)
    false
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { financekit_item_id: @item.id, batch_id: batch&.batch_id })
    fail_batch!(batch, "processing_error", permanent: false, error_class: error.class.name)
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
      amount = Financekit::Payload.money!(money)
      observation = mapping.financekit_balance_observations.find_or_create_by!(source_id: record["source_id"],
        kind: record["kind"], observed_at: observed_at) do |balance|
        balance.financekit_account = mapping
        balance.amount = amount
        balance.currency = money["currency"]
        balance.direction = money["direction"]
      end
      # A stored observation is immutable, so the retained value and the
      # canonical balance both stay as they are. Detecting the disagreement is
      # right; ending ingestion over it is not. Fencing here would clear the
      # upload credential, and only a foreground OAuth repair can reissue one —
      # the same reason import validation retries rather than fences. Raise it
      # for the family and carry on with the rest of the capture.
      if observation.amount != amount || observation.currency != money["currency"] ||
          observation.direction != money["direction"]
        counts[create_observation_conflict!(mapping, record, observed_at) ? "review_required" : "settled"] += 1
        return
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

      # "Keep Sure" is a durable decision about this source identity, not a
      # one-off dismissal. The publisher re-sends the same record on every
      # capture that covers it, so without this the resolved conflict reopens
      # on the next batch and the family is asked the same question forever.
      if settled_by_family?(identity)
        identity.refresh_review_required!
        counts["settled"] += 1
        return
      end

      # An unanswered review keeps the record out of the ledger. Importing it
      # on the next capture would decide the question the family was asked.
      if existed && identity.review_required?
        settle_edited_pending_entry!(identity.entry, record)
        identity.save!
        counts["review_required"] += 1
        return
      end

      if !existed && @item.replaces_financekit_item_id.present? &&
          mapping.financekit_account_lineage.financekit_transactions.exists?
        identity.review_required = true
        identity.save!
        create_conflict!(mapping, identity, "replacement_identity")
        counts["review_required"] += 1
        return
      end
      if identity.tombstoned_at || (existed && identity.entry_id.nil? && identity.ledger_imported)
        identity.update!(review_required: true)
        create_conflict!(mapping, identity, "source_reappeared")
        counts["review_required"] += 1
        return
      end
      if %w[rejected memo unknown].include?(record["status"])
        remove_source_only_entry!(mapping, identity, counts) if identity.entry
        identity.ledger_imported = false unless identity.review_required?
        identity.save!
        counts["source_only"] += 1
        return
      end

      account = mapping.account
      account.with_lock do
        entry = identity.entry
        entry&.lock!
        if entry && protected_entry?(entry)
          settle_edited_pending_entry!(entry, record)
          identity.update!(review_required: true)
          create_conflict!(mapping, identity, "protected_entry")
          counts["review_required"] += 1
          return
        end

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
      if entry && settled_by_family?(identity)
        # The family already chose to keep Sure's entry for this identity. The
        # tombstone is still recorded so the source cannot resurrect it, but the
        # protected entry stays and the answered conflict is not reopened.
        # Review state follows the same rule as resolution and upserts: it is
        # open while any conflict about this record still is.
        identity.review_required = identity.review_required_from_conflicts
        counts["settled"] += 1
      elsif entry
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
      Financekit::Diagnostics.capture(item: @item, batch: batch, source: self.class.name,
        message: "FinanceKit tombstone processed", event: "tombstone_processed",
        account_provider: mapping.financekit_account_lineage.account_provider,
        source_identity_id: identity.id, review_required: identity.review_required)
    end

    # A conflict the family resolved with "keep_sure" settles that source
    # identity for good: Sure's version wins and the publisher's copy of the
    # record is recorded without touching the ledger or raising again.
    def settled_by_family?(identity)
      identity.persisted? && settled_identity_ids.include?(identity.id)
    end

    # Read once per apply rather than per record: a capture carries up to
    # Financekit::MAX_RECORDS events and this runs inside the item row lock.
    # Scoped to the family, not the connection, so a decision survives device
    # replacement the same way the source identity behind it does. Conflicts
    # opened during this apply are "open", so the set cannot change under us.
    def settled_identity_ids
      @settled_identity_ids ||= FinancekitConflict
        .where(family_id: @item.family_id, resolution: "keep_sure")
        .where.not(financekit_transaction_id: nil)
        .distinct.pluck(:financekit_transaction_id).to_set
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

    # Ordered cheapest first: every check below the columns loads an
    # association, and transfer/split membership each cost a query.
    def protected_entry?(entry)
      entry.protected_from_sync? || entry.reconciled_at.present? || entry.split_child? ||
        entry.locked_attributes.present? || entry.transaction.locked_attributes.present? ||
        entry.transaction.transfer_id.present? || entry.transaction.transfer.present? ||
        entry.split_parent?
    end

    # Preserve the shared importer's pending-to-booked exception for user edits,
    # without changing the edited ledger fields or bypassing an import lock.
    def settle_edited_pending_entry!(entry, record)
      return unless entry && record["status"] == "booked"

      Entry.transaction do
        entry.lock!
        return unless entry.user_modified? && !entry.excluded? && !entry.import_locked?

        transaction = entry.transaction
        if transaction.extra&.dig("financekit", "pending")
          transaction.update!(extra: transaction.extra.deep_merge("financekit" => { "pending" => false }))
        end
      end
    end

    # Balance observations have no source transaction, so the conflict hangs off
    # the lineage and carries the observation identity in its details. Returns
    # whether the record still needs review.
    #
    # Matching on that identity rather than the lineage alone is what makes
    # "keep Sure" durable here, the same way it is for a source transaction: the
    # publisher re-sends the same disagreement on every capture that covers it,
    # so keying the lookup on open rows made the decision last one capture. A
    # different observation still opens its own conflict.
    def create_observation_conflict!(mapping, record, observed_at)
      # Canonical UTC, not the wire string: the observation itself is keyed on
      # the parsed instant, so two payloads spelling the same moment differently
      # hit one observation and must consult one decision.
      details = { "source_id" => record["source_id"], "kind" => record["kind"],
        "observed_at" => observed_at.utc.iso8601(6) }
      # Searched across the family rather than this connection, the same way a
      # source transaction's decision is, because the observation lives on the
      # lineage and outlives the publisher that sent it. A replacement device
      # must not reopen a question the family already answered. The new row
      # still belongs to the connection that raised it.
      history = FinancekitConflict.where(family_id: @item.family_id)
        .where(kind: "balance_observation_conflict",
          financekit_account_lineage_id: mapping.financekit_account_lineage_id)
        .where("details @> ?::jsonb", details.to_json)
      return false if history.exists?(resolution: "keep_sure")
      return true if history.open.exists?

      # The check above cannot settle it alone: two publishers can share one
      # lineage — a replacement device keeps the lineage of the device it
      # replaces — so both can find no open row and then both insert. The
      # financekit_conflicts_open_observation index decides which one wins. In a
      # savepoint because a unique violation aborts the surrounding transaction,
      # and this import has the rest of the capture still to apply.
      begin
        FinancekitConflict.transaction(requires_new: true) do
          @item.financekit_conflicts.create!(family: @item.family,
            financekit_account_lineage: mapping.financekit_account_lineage,
            kind: "balance_observation_conflict", status: "open", details: details)
        end
      rescue ActiveRecord::RecordNotUnique
        # The other publisher asked first. The question is open either way, and
        # the row belongs to whichever connection got there first.
        nil
      end
      true
    end

    def create_conflict!(mapping, identity, kind)
      @item.financekit_conflicts.find_or_create_by!(financekit_transaction: identity, kind: kind, status: "open") do |conflict|
        conflict.family = @item.family
        conflict.financekit_account_lineage = mapping.financekit_account_lineage
        conflict.details = { "source_id" => identity.source_id }
      end
    end

    def fail_batch!(batch, code, permanent:, error_class:)
      unless batch
        Financekit::Diagnostics.capture(item: @item, source: self.class.name, level: "error",
          message: "FinanceKit import blocked", event: "import_blocked", error_code: code, error_class: error_class)
        return
      end

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
      retrying = batch.status == "accepted"
      Financekit::Diagnostics.capture(item: @item, batch: batch, source: self.class.name,
        level: retrying ? "warn" : "error",
        message: retrying ? "FinanceKit import retry scheduled" : "FinanceKit import requires repair",
        event: retrying ? "import_retry" : "import_failed", error_code: code, error_class: error_class)
    end
end
