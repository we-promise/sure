require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RetainedTransactionsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Replay = Provider::AccountData::RetainedTransactions

  setup do
    Provider::AccountData::Up.stubs(:native_ready?).returns(true)
  end

  test "new authorized replay publishes latest values without changing original captures or checkpoints" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("purchase", amount: "12") ])
      capture(connection, external, records: [ record("purchase", amount: "14") ])
      before = retained_state(connection)
      account = link(external)
      original_source = SourceRecord.find_by!(external_account: external, external_id: "purchase")
      receipt = replay(external)

      assert receipt.applied?
      assert_equal "retained-transactions:#{external.id}", receipt.scope_key
      assert_equal before, retained_state(connection, except: receipt.id)
      assert_equal BigDecimal("14"), account.entries.sole.amount
      assert_equal original_source.id, SourceRecord.find_by!(external_account: external, external_id: "purchase").id
      assert_equal account.id, original_source.reload.account_id
      assert_equal receipt.id, original_source.ingestion_batch_id
      assert_not external.reload.transaction_backfill_required?
      page = Ingestion::Codec.load(receipt.payload)
      assert_equal false, page.coverage["history_complete"]
      assert_equal false, page.coverage["pending_absence_authoritative"]
      assert_equal 2, page.evidence.fetch("retained_transactions").fetch("captures").size
      assert_provider_column_encrypted receipt, :payload, "purchase"
    end
  end

  test "identical retry returns the original receipt and posting UUIDs" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("retry") ])
      account = link(external)
      sync = connection.syncs.create!
      first = replay(external, sync: sync)
      ids = [ account.entries.sole.id, account.entries.sole.entryable_id ]
      assert_no_difference [ "IngestionBatch.count", "Entry.count", "EntrySource.count" ] do
        assert_equal first.id, replay(external, sync: sync).id
      end
      assert_equal ids, [ account.entries.sole.id, account.entries.sole.entryable_id ]
    end
  end

  test "explicit pending and posted observations share one financial UUID and retain the alias" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("pending", pending: true) ])
      capture(connection, external, records: [ record("posted", pending_external_id: "pending") ])
      account = link(external)
      replay(external)
      pending = SourceRecord.find_by!(external_account: external, external_id: "pending")
      posted = SourceRecord.find_by!(external_account: external, external_id: "posted")
      assert_equal 1, account.entries.count
      assert_equal pending.entry_source.entry_id, posted.entry_source.entry_id
      assert pending.withdrawn?
      assert_equal "posted", posted.entry.external_id
      assert_includes posted.entry.transaction.extra.fetch("auto_claimed_pending_ids"), "pending"

      capture(connection, external, records: [ record("pending", pending: true) ])
      assert_equal 1, account.entries.count
      assert_equal "posted", account.entries.sole.external_id
    end
  end

  test "withdrawn-only observations bind their exact tombstones without creating entries" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("removed", pending: true) ])
      capture(connection, external, removed: [ "removed" ])
      account = link(external)
      assert_no_difference "Entry.count" do
        receipt = replay(external)
        row = SourceRecord.find_by!(external_account: external, external_id: "removed")
        assert row.withdrawn?
        assert_not row.pending?
        assert_equal account.id, row.account_id
        assert_equal receipt.id, row.ingestion_batch_id
        assert_empty row.entry_sources
      end
    end
  end

  test "secondary source selection binds observations without financial authority" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("secondary") ])
      account = link(external)
      other_connection = create_provider_connection(provider_key: "mercury")
      other = create_external_account(other_connection)
      selection = AccountProvider.create!(account: account, external_account: other)
      policy = Account::SourcePolicy.select!(account: account, account_provider: selection, resource: "transactions")
      assert_no_difference "Entry.count" do
        receipt = replay(external)
        assert_equal policy.id, receipt.source_policy_version
        row = SourceRecord.find_by!(external_account: external, external_id: "secondary")
        assert_equal account.id, row.account_id
        assert_empty row.entry_sources
      end
      assert_not external.reload.transaction_backfill_required?
    end
  end

  test "an ordinary publication failure rolls back entries observations receipt and backfill clearing" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("rollback") ])
      account = link(external)
      before = retained_state(connection)
      callback = -> { raise IOError, "test publication failure" }
      Transaction.set_callback(:create, :after, callback)
      begin
        assert_raises(IOError) { replay(external) }
      ensure
        Transaction.skip_callback(:create, :after, callback)
      end
      assert_equal before, retained_state(connection)
      assert_empty account.entries
      row = SourceRecord.find_by!(external_account: external, external_id: "rollback")
      assert_nil row.account_id
      assert_empty row.entry_sources
      assert external.reload.transaction_backfill_required?
      assert replay(external).applied?
      assert_equal 1, account.entries.count
    end
  end

  test "posted identity referencing a withdrawn predecessor requires reconciliation" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("pending", pending: true) ])
      capture(connection, external, records: [ record("posted", pending_external_id: "pending") ], removed: [ "pending" ])
      link(external)
      assert_refused_without_publication(external)
    end
  end

  test "two posted identities cannot claim the same retained pending identity" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("pending", pending: true),
        record("posted-one", pending_external_id: "pending"), record("posted-two", pending_external_id: "pending") ])
      link(external)
      assert_refused_without_publication(external)
    end
  end

  test "missing observation and rewound latest pointers do not silently omit captured changes" do
    with_context do |connection, external|
      first = capture(connection, external, records: [ record("changed", amount: "11") ])
      capture(connection, external, records: [ record("changed", amount: "12") ])
      link(external)
      row = SourceRecord.find_by!(external_account: external, external_id: "changed")
      row.update!(ingestion_batch: first.children.sole)
      assert_refused_without_publication(external)
      row.delete
      assert_refused_without_publication(external)
    end
  end

  test "same-ID observations of another external account are not included" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("same-id") ])
      other = create_external_account(connection)
      foreign = capture(connection, other, records: [ record("same-id") ])
      link(external)
      receipt = replay(external)
      evidence = Ingestion::Codec.load(receipt.payload).evidence.fetch("retained_transactions")
      assert_not_includes evidence.fetch("captures").map { |row| row.fetch("batch_id") }, foreign.children.sole.id
      assert_nil SourceRecord.find_by!(external_account: other, external_id: "same-id").account_id
    end
  end

  test "a wholly deleted earlier child remains detectable through the original generation" do
    with_context do |connection, external|
      earlier = capture(connection, external, records: [ record("lost-earlier") ])
      capture(connection, external, records: [ record("still-present") ])
      SourceRecord.where(external_account: external, external_id: "lost-earlier").delete_all
      earlier.children.delete_all
      link(external)
      assert_refused_without_publication(external)
    end
  end

  test "existing same-provider financial identities are not adopted without a mapping" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("existing") ])
      account = link(external)
      entry = account.entries.create!(source: "up", external_id: "existing", name: "Original", amount: 7,
        currency: "USD", date: Date.current, entryable: Transaction.new)
      assert_refused_without_publication(external)
      assert_equal BigDecimal("7"), entry.reload.amount
    end
  end

  test "previously bound secondary observations cannot be relinked by this command" do
    with_context do |connection, external|
      account = link(external)
      alternate = create_external_account(create_provider_connection(provider_key: "mercury"))
      selected = AccountProvider.create!(account: account, external_account: alternate)
      Account::SourcePolicy.select!(account: account, account_provider: selected, resource: "transactions")
      capture(connection, external, records: [ record("already-bound") ])
      assert SourceRecord.find_by!(external_account: external).account_id
      assert_refused_without_publication(external)
    end
  end

  test "record and stored-byte budgets refuse before financial publication" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("budget-one"), record("budget-two", amount: "13") ])
      link(external)
      stub_const(Replay, :MAX_RECORDS, 1) { assert_refused_without_publication(external, error: Replay::TooLarge) }
      stub_const(Replay, :MAX_BYTES, 1) { assert_refused_without_publication(external, error: Replay::TooLarge) }
    end
  end

  test "active leases and cancelled setup syncs deny replay" do
    with_context do |connection, external|
      capture(connection, external, records: [ record("busy") ])
      link(external)
      connection.update!(lease_owner: SecureRandom.uuid, lease_expires_at: 1.minute.from_now)
      assert_refused_without_publication(external)
      connection.update!(lease_owner: nil, lease_expires_at: nil)
      sync = connection.syncs.create!(cancel_requested_at: Time.current)
      assert_raises(Replay::Conflict) { replay(external, sync: sync) }
    end
  end

  test "empty discovery returns nil and does not claim archival cache or other resources were replayed" do
    with_context do |connection, external|
      link(external)
      assert_no_difference "IngestionBatch.count" do
        assert_nil replay(external)
      end
      external.update!(transaction_backfill_required: true)
      assert_refused_without_publication(external)
    end
  end

  test "an empty retained generation cannot explain a required nonempty backfill" do
    with_context do |connection, external|
      capture(connection, external)
      link(external)
      external.update!(transaction_backfill_required: true)
      assert_refused_without_publication(external)
    end
  end

  private
    def with_context
      with_provider_encryption do
        connection = create_provider_connection
        external = create_external_account(connection)
        yield connection, external
      end
    end

    def record(id, amount: "12.34", pending: false, pending_external_id: nil)
      Ingestion::Record.transaction(external_id: id, name: "Retained #{id}", amount: BigDecimal(amount),
        currency: "USD", date: Date.current, pending: pending, pending_external_id: pending_external_id)
    end

    def capture(connection, external, records: [], removed: [])
      reader = Object.new
      reader.define_singleton_method(:fetch_transaction_group) do |**request|
        page = Provider::AccountData::Page.new(records: records, removed_ids: removed, complete: false)
        Provider::AccountData::TransactionGroup.new(generation_id: request.fetch(:generation_id), start_cursor: request[:start_cursor],
          request_cursor: request[:cursor], next_cursor: SecureRandom.uuid, complete: true,
          account_pages: { external.external_id => page }, unassigned_removed_ids: [], evidence: {})
      end
      Provider::AccountData::TransactionSync.new(connection: connection, sync: connection.syncs.create!, adapter: reader,
        writer_epoch: connection.writer_epoch, fence: ->(&block) { connection.with_lock(&block) }).perform
    end

    def link(external)
      account = external.family.accounts.create!(name: "Retained setup", currency: "USD", balance: 0,
        accountable: Depository.new, subtype: "checking")
      provider = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: provider, resource: "transactions")
      account
    end

    def replay(external, sync: external.provider_connection.syncs.create!)
      ApplicationRecord.transaction(requires_new: true) { Replay.new(external_account: external, sync: sync).call }
    end

    def retained_state(connection, except: nil)
      { batches: connection.ingestion_batches.where.not(id: except).order(:id).map { |row| row.attributes.deep_dup },
        generations: connection.provider_sync_generations.order(:id).map { |row| row.attributes.deep_dup },
        checkpoints: connection.provider_sync_checkpoints.order(:id).map { |row| row.attributes.deep_dup } }
    end

    def assert_refused_without_publication(external, error: Replay::Conflict)
      before = SourceRecord.where(external_account: external).order(:id).map(&:attributes)
      assert_no_difference [ "IngestionBatch.count", "Entry.count", "EntrySource.count" ] do
        assert_raises(error) { replay(external) }
      end
      assert_equal before, SourceRecord.where(external_account: external).order(:id).map(&:attributes)
    end

    def stub_const(owner, name, value)
      original = owner.const_get(name)
      owner.send(:remove_const, name)
      owner.const_set(name, value)
      yield
    ensure
      owner.send(:remove_const, name)
      owner.const_set(name, original)
    end
end
