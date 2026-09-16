require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::MappedEntryPublicationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    Provider::AccountData::Registry.stubs(:fetch).with("plaid").returns(Provider::AccountData::Plaid)
  end

  test "native cash import adopts a reviewed plaid_id-only UUID and preserves locked names" do
    with_provider_encryption do
      external = linked_account
      entry = legacy_entry(plaid_id: "older", locked_attributes: { "name" => true })
      observe_mapping(external, entry, "older", match_method: "legacy_plaid_id")

      assert_no_difference "Entry.count" do
        publish(external, page(transaction("older", amount: 71)))
      end

      assert_equal BigDecimal("71"), entry.reload.amount
      assert_equal "My existing entry", entry.name
      assert_nil entry.external_id
      assert_nil entry.source
      assert_equal entry.id, SourceRecord.find_by!(external_account: external, external_id: "older").entry.id
    end
  end

  test "protected adopted cash is unchanged and cannot enrich merchants or bootstrap categories" do
    with_provider_encryption do
      external = linked_account
      entry = legacy_entry(plaid_id: "protected", user_modified: true, excluded: true, import_locked: true)
      observe_mapping(external, entry, "protected", match_method: "legacy_plaid_id")
      before = [ entry.reload.attributes, entry.transaction.reload.attributes ]
      metadata = { category_bootstrap: "empty_family", merchant: { external_id: "must-not-create", name: "Changed merchant" } }

      assert_no_difference [ "Entry.count", "ProviderMerchant.count", "Category.count", "DataEnrichment.count" ] do
        publish(external, page(transaction("protected", amount: 71, metadata: metadata)))
      end

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
    end
  end

  test "a protected legacy Trade keeps its UUID quantity price and amount in native activities" do
    with_provider_encryption do
      external = linked_account(account: accounts(:investment))
      entry = entries(:trade)
      entry.update!(plaid_id: "legacy-trade", user_modified: true)
      observe_mapping(external, entry, "legacy-trade", kind: "activity", match_method: "legacy_plaid_id")
      before = [ entry.reload.attributes, entry.trade.reload.attributes ]
      record = Ingestion::Record.activity(external_id: "legacy-trade", name: "New title", date: Date.current, currency: "USD",
        activity_type: "buy", quantity: BigDecimal("2"), price: BigDecimal("10"), amount: BigDecimal("20"), security: { ticker: "AAPL" })

      assert_no_difference [ "Entry.count", "Trade.count" ] { publish(external, page(record), stream: "activities") }

      assert_equal before, [ entry.reload.attributes, entry.trade.reload.attributes ]
    end
  end

  test "explicit pending promotion checks user protection before changing the selected financial UUID" do
    with_provider_encryption do
      external = linked_account
      pending_date = Date.current - 3
      publish(external, page(transaction("pending", pending: true, amount: 10, date: pending_date)))
      entry = external.current_account.entries.find_by!(source: "plaid", external_id: "pending")
      entry.update!(user_modified: true, name: "Keep this edit")
      id = entry.id

      assert_no_difference "Entry.count" do
        publish(external, page(transaction("booked", amount: 12, pending_external_id: "pending")))
      end

      assert_equal id, entry.reload.id
      assert_equal "booked", entry.external_id
      assert_equal BigDecimal("10"), entry.amount
      assert_equal pending_date, entry.date
      assert_equal "Keep this edit", entry.name
      assert entry.user_modified?
      assert_not entry.transaction.pending?
      assert_includes entry.transaction.extra.fetch("auto_claimed_pending_ids"), "pending"
      pending = SourceRecord.find_by!(external_account: external, external_id: "pending")
      assert pending.withdrawn?
      assert_not pending.pending?
      assert_equal id, pending.entry.id
      assert_equal id, SourceRecord.find_by!(external_account: external, external_id: "booked").entry.id
    end
  end

  test "retired aliases stay suppressed when excluded or import-locked financial pending state is retained" do
    with_provider_encryption do
      external = linked_account
      %i[excluded import_locked].each_with_index do |protection, index|
        pending_id, booked_id = "pending-#{index}", "booked-#{index}"
        pending_record = transaction(pending_id, pending: true, amount: 20 + index)
        publish(external, page(pending_record))
        entry = external.current_account.entries.find_by!(external_id: pending_id, source: "plaid")
        entry.update!(protection => true)
        publish(external, page(transaction(booked_id, pending_external_id: pending_id, amount: 40 + index)))
        before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

        assert_no_difference [ "Entry.count", "EntrySource.count", "SourceRecord.count", "DataEnrichment.count" ] do
          publish(external, page(pending_record))
        end

        assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
        assert_equal booked_id, entry.external_id
        assert entry.transaction.pending?
        assert SourceRecord.find_by!(external_account: external, external_id: pending_id).withdrawn?
      end
    end
  end

  test "unprotected pending promotion retains the original date and replay order cannot recreate a pending Entry" do
    with_provider_encryption do
      external = linked_account
      pending = transaction("pending", pending: true, amount: 10, date: Date.current - 3)
      posted = transaction("posted", pending_external_id: "pending", amount: 12, date: Date.current)
      publish(external, page(pending))
      entry = external.current_account.entries.find_by!(source: "plaid", external_id: "pending")
      id = entry.id
      publish(external, page(posted))

      [ [ pending, posted ], [ posted, pending ] ].each do |records|
        assert_no_difference [ "Entry.count", "EntrySource.count", "SourceRecord.count" ] { publish(external, page(*records)) }
        assert_equal id, entry.reload.id
        assert_equal "posted", entry.external_id
        assert_equal BigDecimal("12"), entry.amount
        assert_equal Date.current - 3, entry.date
        assert_not entry.transaction.pending?
      end
    end
  end

  test "an unbackfilled legacy plaid_id cannot be replaced by a new native Entry" do
    with_provider_encryption do
      external = linked_account
      entry = legacy_entry(plaid_id: "missing-review")
      before = entry.attributes
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Ingestion::MappedEntryResolver::Conflict) { publish(external, page(transaction("missing-review"))) }
      end
      assert_equal before, entry.reload.attributes
    end
  end

  test "unmapped transactions cannot claim legacy IDs provider sources or provider evidence by financial resemblance" do
    with_provider_encryption do
      external = linked_account
      rows = [ legacy_entry(plaid_id: "legacy", amount: 50), legacy_entry(source: "up", amount: 51), legacy_entry(amount: 52) ]
      observe_mapping(external, rows.last, "reviewed-evidence", role: "evidence")
      before = rows.map(&:attributes)

      rows.each_with_index do |entry, index|
        assert_difference "Entry.count", 1 do
          publish(external, page(transaction("genuinely-new-#{index}", amount: entry.amount, date: entry.date)))
        end
      end

      assert_equal before, rows.map { |entry| entry.reload.attributes }
    end
  end

  test "native mode retains protected manual and CSV-style claims for unowned rows" do
    with_provider_encryption do
      external = linked_account
      entry = legacy_entry(amount: 81, import_locked: true)
      original_id = entry.id
      assert_no_difference "Entry.count" { publish(external, page(transaction("manual-claim", amount: 81, date: entry.date))) }
      assert_equal original_id, entry.reload.id
      assert_equal "manual-claim", entry.external_id
      assert_equal "My existing entry", entry.name
      assert entry.import_locked?
    end
  end

  test "a mapping conflict rolls back prior mutations from the same page" do
    with_provider_encryption do
      external = linked_account
      entry = legacy_entry(plaid_id: "collision")
      observation = observe_mapping(external, entry, "collision", match_method: "legacy_plaid_id")
      legacy_entry(source: "plaid", external_id: "collision")
      observation_before = observation.attributes
      records = [ transaction("earlier-in-page", amount: 98), transaction("collision", amount: 99) ]

      assert_no_difference [ "Entry.count", "Transaction.count", "EntrySource.count", "SourceRecord.count" ] do
        assert_raises(Ingestion::MappedEntryResolver::Conflict) { publish(external, page(*records)) }
      end

      assert_equal observation_before, observation.reload.attributes
    end
  end

  test "native mode cannot claim an old pending ledger identity without reviewed source evidence" do
    with_provider_encryption do
      external = linked_account
      entry = legacy_entry(source: "plaid", external_id: "old-pending", extra: { "plaid" => { "pending" => true } })
      before = [ entry.attributes, entry.transaction.attributes ]
      assert_no_difference "Entry.count" do
        assert_raises(Ingestion::MappedEntryResolver::Conflict) do
          publish(external, page(transaction("posted", pending_external_id: "old-pending")))
        end
      end
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
    end
  end

  test "a retired pending alias tombstone only withdraws that observation" do
    with_provider_encryption do
      external = linked_account
      publish(external, page(transaction("pending-alias", pending: true)))
      entry = external.current_account.entries.find_by!(external_id: "pending-alias", source: "plaid")
      entry.update!(excluded: true)
      publish(external, page(transaction("current-posting", pending_external_id: "pending-alias")))
      alias_record = SourceRecord.find_by!(external_account: external, external_id: "pending-alias")
      # Historical evidence may still describe the pending observation. Its
      # recorded alias, rather than the mutable pending badge, determines rights.
      alias_record.update!(pending: true, withdrawn: false)
      original = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      2.times do
        assert_no_difference [ "Entry.count", "EntrySource.count", "SourceRecord.count" ] do
          publish(external, removals("pending-alias"))
        end
      end

      assert_equal original, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert alias_record.reload.withdrawn?
      assert_not alias_record.pending?
      assert_equal entry.id, alias_record.entry.id
      assert_not SourceRecord.find_by!(external_account: external, external_id: "current-posting").withdrawn?
    end
  end

  test "removing a current posting and its retired alias is independent of removal order" do
    with_provider_encryption do
      external = linked_account
      [ false, true ].each_with_index do |reverse, index|
        pending_id, posted_id = "pending-removal-#{index}", "posted-removal-#{index}"
        publish(external, page(transaction(pending_id, pending: true)))
        publish(external, page(transaction(posted_id, pending_external_id: pending_id)))
        entry = external.current_account.entries.find_by!(external_id: posted_id, source: "plaid")
        SourceRecord.find_by!(external_account: external, external_id: pending_id).update!(pending: true, withdrawn: false)
        ids = reverse ? [ posted_id, pending_id ] : [ pending_id, posted_id ]

        assert_difference "Entry.count", -1 do
          publish(external, removals(*ids))
        end
        assert_not Entry.exists?(entry.id)
        assert SourceRecord.where(external_account: external, external_id: ids).all?(&:withdrawn?)
        assert_no_difference "Entry.count" { publish(external, removals(*ids)) }
      end
    end
  end

  test "pending absence cannot clear a posted entry through a retired alias" do
    with_provider_encryption do
      external = linked_account
      publish(external, page(transaction("absent-alias", pending: true)))
      entry = external.current_account.entries.find_by!(external_id: "absent-alias", source: "plaid")
      entry.update!(import_locked: true)
      publish(external, page(transaction("retained-posting", pending_external_id: "absent-alias")))
      alias_record = SourceRecord.find_by!(external_account: external, external_id: "absent-alias")
      alias_record.update!(pending: true, withdrawn: false)
      original = [ entry.reload.attributes, entry.transaction.reload.attributes ]
      snapshot = Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot", coverage: { pending_scope: "all" })

      publish(external, snapshot)

      assert_equal original, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert alias_record.reload.withdrawn?
      assert_not SourceRecord.find_by!(external_account: external, external_id: "retained-posting").withdrawn?
    end
  end

  test "tombstones reject unbackfilled legacy Plaid identities" do
    with_provider_encryption do
      external = linked_account
      entry = legacy_entry(plaid_id: "unmapped-removal")
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::InvalidResponse) { publish(external, removals("unmapped-removal")) }
      end
      assert Entry.exists?(entry.id)
    end
  end

  test "a reviewed current legacy Plaid mapping permits exact removal without rewriting its identity" do
    with_provider_encryption do
      external = linked_account
      entry = legacy_entry(plaid_id: "reviewed-removal")
      observation = observe_mapping(external, entry, "reviewed-removal", match_method: "legacy_plaid_id")
      assert_difference "Entry.count", -1 do
        publish(external, removals("reviewed-removal"))
      end
      assert observation.reload.withdrawn?
      assert_equal entry.id, observation.entry_sources.sole.entry_identity
      assert_not observation.entry_sources.sole.active?
    end
  end

  test "pending absence uses reviewed source identities for legacy Plaid entries without compatibility fields" do
    with_provider_encryption do
      external = linked_account
      missing = legacy_entry(plaid_id: "missing-legacy-pending", extra: { "plaid" => { "pending" => true } })
      present = legacy_entry(plaid_id: "present-legacy-pending", extra: { "plaid" => { "pending" => true } })
      [ missing, present ].each do |entry|
        observe_mapping(external, entry, entry.plaid_id, match_method: "legacy_plaid_id").update!(pending: true)
      end
      snapshot = Provider::AccountData::Page.new(records: [ transaction(present.plaid_id, pending: true) ],
        complete: true, mode: "snapshot", coverage: { pending_scope: "all" })

      assert_difference "Entry.count", -1 do
        publish(external, snapshot)
      end

      assert_not Entry.exists?(missing.id)
      assert present.reload.transaction.pending?
      assert_nil present.source
      assert_nil present.external_id
      assert SourceRecord.find_by!(external_account: external, external_id: missing.plaid_id).withdrawn?
      assert_not SourceRecord.find_by!(external_account: external, external_id: present.plaid_id).withdrawn?
    end
  end

  test "a retired alias does not keep a removed posting alive across separate tombstone batches" do
    with_provider_encryption do
      external = linked_account
      [ false, true ].each_with_index do |posted_first, index|
        pending_id, posted_id = "split-pending-#{index}", "split-posted-#{index}"
        publish(external, page(transaction(pending_id, pending: true)))
        publish(external, page(transaction(posted_id, pending_external_id: pending_id)))
        entry = external.current_account.entries.find_by!(external_id: posted_id, source: "plaid")
        SourceRecord.find_by!(external_account: external, external_id: pending_id).update!(pending: true, withdrawn: false)
        ordered_ids = posted_first ? [ posted_id, pending_id ] : [ pending_id, posted_id ]

        ordered_ids.each do |id|
          expected_change = id == posted_id ? -1 : 0
          assert_difference "Entry.count", expected_change do
            publish(external, removals(id))
          end
        end

        assert_not Entry.exists?(entry.id)
        assert SourceRecord.where(external_account: external, external_id: ordered_ids).all?(&:withdrawn?)
        assert_equal [ entry.id ], EntrySource.where(source_record: SourceRecord.where(external_account: external, external_id: ordered_ids))
          .distinct.pluck(:entry_identity)
      end
    end
  end

  test "exact tombstones preserve rejected transfer decisions and the original posting" do
    with_provider_encryption do
      external = linked_account
      publish(external, page(transaction("rejected-transfer")))
      entry = external.current_account.entries.find_by!(source: "plaid", external_id: "rejected-transfer")
      counterpart = legacy_entry(amount: -32)
      rejection = RejectedTransfer.create!(inflow_transaction: counterpart.transaction, outflow_transaction: entry.transaction)
      original = [ entry.reload.attributes, entry.transaction.reload.attributes, rejection.attributes, counterpart.attributes ]

      assert_no_difference [ "Entry.count", "Transaction.count", "RejectedTransfer.count" ] do
        publish(external, removals("rejected-transfer"))
      end

      assert_equal original, [ entry.reload.attributes, entry.transaction.reload.attributes, rejection.reload.attributes, counterpart.reload.attributes ]
      assert SourceRecord.find_by!(external_account: external, external_id: "rejected-transfer").withdrawn?
    end
  end

  test "exact tombstones retain matched goal and recurring payment identities" do
    with_provider_encryption do
      external = linked_account
      publish(external, page(transaction("goal-payment"), transaction("recurring-payment")))
      goal_entry = external.current_account.entries.find_by!(source: "plaid", external_id: "goal-payment")
      recurring_entry = external.current_account.entries.find_by!(source: "plaid", external_id: "recurring-payment")
      pledge = goal_pledges(:open_transfer)
      pledge.update!(matched_transaction: goal_entry.transaction, status: "matched")
      occurrence = RecurringOccurrence.create!(recurring_transaction: recurring_transactions(:netflix_subscription),
        family: external.family, original_due_on: Date.current, due_on: Date.current, currency: "USD")
      allocation = occurrence.allocations.create!(entry: recurring_entry, allocated_amount: 32, currency: "USD",
        state: "confirmed", source: "user_confirmed")
      original = [ goal_entry.attributes, recurring_entry.attributes, pledge.reload.attributes, allocation.attributes ]

      assert_no_difference [ "Entry.count", "Transaction.count", "GoalPledge.count", "RecurringAllocation.count" ] do
        publish(external, removals("goal-payment", "recurring-payment"))
      end

      assert_equal original, [ goal_entry.reload.attributes, recurring_entry.reload.attributes, pledge.reload.attributes, allocation.reload.attributes ]
      assert SourceRecord.where(external_account: external, external_id: %w[goal-payment recurring-payment]).all?(&:withdrawn?)
    end
  end

  test "exact tombstones retain recurring rejections and price history references" do
    with_provider_encryption do
      external = linked_account
      publish(external, page(transaction("rejected-recurring"), transaction("changed-price")))
      rejected = external.current_account.entries.find_by!(source: "plaid", external_id: "rejected-recurring")
      changed = external.current_account.entries.find_by!(source: "plaid", external_id: "changed-price")
      series = recurring_transactions(:netflix_subscription)
      rejection = RecurringMatchRejection.create!(recurring_transaction: series, entry: rejected)
      price = RecurringPriceChange.create!(recurring_transaction: series, entry: changed, previous_amount: 15.99,
        new_amount: 32, currency: "USD", effective_on: Date.current, source: "detected")
      original = [ rejected.attributes, changed.attributes, rejection.attributes, price.attributes ]

      assert_no_difference [ "Entry.count", "Transaction.count", "RecurringMatchRejection.count", "RecurringPriceChange.count" ] do
        publish(external, removals("rejected-recurring", "changed-price"))
      end

      assert_equal original, [ rejected.reload.attributes, changed.reload.attributes, rejection.reload.attributes, price.reload.attributes ]
    end
  end

  test "an attached receipt survives exact source withdrawal without purging storage" do
    with_provider_encryption do
      external = linked_account
      publish(external, page(transaction("receipt")))
      entry = external.current_account.entries.find_by!(source: "plaid", external_id: "receipt")
      entry.transaction.attachments.attach(io: StringIO.new("%PDF-1.4\nreceipt fixture\n"), filename: "receipt.pdf",
        content_type: "application/pdf", identify: false)
      attachment = entry.transaction.attachments.sole
      blob = attachment.blob
      original = [ entry.reload.attributes, entry.transaction.reload.attributes, attachment.attributes, blob.attributes ]

      assert_no_difference [ "Entry.count", "Transaction.count", "ActiveStorage::Attachment.count", "ActiveStorage::Blob.count" ] do
        publish(external, removals("receipt"))
      end

      assert_equal original, [ entry.reload.attributes, entry.transaction.reload.attributes, attachment.reload.attributes, blob.reload.attributes ]
      assert_equal "%PDF-1.4\nreceipt fixture\n", blob.download
      assert SourceRecord.find_by!(external_account: external, external_id: "receipt").withdrawn?
    ensure
      attachment&.delete
      blob&.purge
    end
  end

  test "withdrawal cannot cascade through a transaction shared by another financial entry" do
    with_provider_encryption do
      external = linked_account
      publish(external, page(transaction("shared-transaction")))
      entry = external.current_account.entries.find_by!(source: "plaid", external_id: "shared-transaction")
      other = external.current_account.entries.create!(name: "Other retained entry", amount: 32, currency: "USD",
        date: entry.date, entryable: entry.transaction)
      original = [ entry.reload.attributes, entry.transaction.reload.attributes, other.attributes ]

      assert_no_difference [ "Entry.count", "Transaction.count" ] { publish(external, removals("shared-transaction")) }

      assert_equal original, [ entry.reload.attributes, entry.transaction.reload.attributes, other.reload.attributes ]
      assert SourceRecord.find_by!(external_account: external, external_id: "shared-transaction").withdrawn?
    end
  end

  private
    def removals(*ids)
      Provider::AccountData::Page.new(records: [], removed_ids: ids, complete: true, mode: "delta",
        coverage: { removal_policy: "exact_external_id" })
    end

    def linked_account(account: accounts(:depository))
      connection = create_provider_connection(provider_key: "plaid")
      external = create_external_account(connection)
      link = AccountProvider.create!(account: account, external_account: external)
      %w[transactions activities].each { |resource| Account::SourcePolicy.select!(account: account, account_provider: link, resource: resource) }
      external
    end

    def legacy_entry(extra: {}, **attributes)
      accounts(:depository).entries.create!({ name: "My existing entry", date: Date.current - 3, amount: 32, currency: "USD",
        entryable: Transaction.new(extra: extra) }.merge(attributes))
    end

    def transaction(id, amount: 32, date: Date.current - 3, pending: false, pending_external_id: nil, metadata: {})
      Ingestion::Record.transaction(external_id: id, name: "New source title", date: date, amount: BigDecimal(amount.to_s), currency: "USD",
        pending: pending, pending_external_id: pending_external_id, metadata: metadata)
    end

    def page(*records)
      Provider::AccountData::Page.new(records: records, complete: true, mode: "delta")
    end

    # Genuine provider observation followed by a reviewed mapping. This fixture
    # never labels migration snapshots as provider API responses or invents Syncs
    # for a migration origin.
    def observe_mapping(external, entry, id, kind: "transaction", match_method: "provider_reconciliation", role: "posting")
      stream = kind == "transaction" ? "transactions" : "activities"
      record = if kind == "transaction"
        transaction(id, amount: entry.amount, date: entry.date)
      else
        Ingestion::Record.activity(external_id: id, name: entry.name, date: entry.date, amount: entry.amount, currency: entry.currency,
          activity_type: "buy", ledger_type: "trade", quantity: entry.trade.qty, price: entry.trade.price, security: { ticker: entry.trade.security.ticker })
      end
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: stream, payload: Ingestion::Codec.dump(page(record)))
      observation = SourceRecord.create!(external_account: external, account: external.current_account, family: external.family,
        ingestion_batch: batch, kind: kind, external_id: id)
      observation.create_entry_source!(entry: entry, account: external.current_account, family: external.family, role: role, match_method: match_method)
      observation
    end

    def publish(external, captured_page, stream: "transactions")
      policy = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: stream)
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: stream,
        payload: Ingestion::Codec.dump(captured_page), source_policy_version: policy.id)
      securities = captured_page.records.filter_map { |record| [ [ record.kind, record[:external_id] ], self.securities(:aapl) ] if record[:security] }.to_h
      IngestionBatch.transaction(requires_new: true) do
        Ingestion::LedgerWriter.new(external_account: external, batch: batch, securities: securities).apply(captured_page)
      end
    end
end
