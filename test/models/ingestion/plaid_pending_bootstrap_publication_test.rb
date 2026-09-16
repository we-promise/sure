require "test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Ingestion::PlaidPendingBootstrapPublicationTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  PENDING_ID = "retained-pending".freeze
  POSTED_ID = "fresh-posted".freeze
  PENDING_DATE = Date.new(2026, 9, 10).freeze
  BASELINE_AMOUNT = BigDecimal("10.25")
  CACHED_AMOUNT = BigDecimal("999.99")
  FRESH_AMOUNT = BigDecimal("12.50")

  test "fresh booked evidence promotes the bootstrapped pending UUID while retaining field locks and original proof" do
    with_pending_bootstrap(locked_attributes: { "name" => true, "date" => true }) do |context, entry, pending, bootstrap_batch|
      original_id = entry.id
      original_proof = pending.entry_source.attributes
      native_batch = capture_fresh_booked(context)

      assert_no_difference [ "Entry.count", "Transaction.count" ] do
        publish(context, native_batch)
      end

      assert_equal original_id, entry.reload.id
      assert_equal POSTED_ID, entry.external_id
      assert_equal "plaid", entry.source
      assert_equal FRESH_AMOUNT, entry.amount
      assert_equal PENDING_DATE, entry.date
      assert_equal "Original financial description", entry.name
      assert entry.locked?(:name)
      assert entry.locked?(:date)
      assert_not entry.transaction.pending?
      assert_includes entry.transaction.extra.fetch("auto_claimed_pending_ids"), PENDING_ID
      posted = observations(context).find_by!(external_id: POSTED_ID)
      assert_equal original_id, posted.entry_source.entry_identity
      assert_equal native_batch.id, posted.ingestion_batch_id
      assert pending.reload.withdrawn?
      assert_not pending.pending?
      assert_equal original_proof, pending.entry_source.reload.attributes
      assert_equal bootstrap_batch.id, pending.entry_source.bootstrap_batch_id
      assert resolver(context).resolve(source_record: pending, kind: "transaction", external_id: PENDING_ID,
        entryable_type: "Transaction").retired_alias?

      # A retry reuses captured provider evidence, rather than replaying the
      # differently valued legacy cache or allocating another financial UUID.
      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        publish(context, native_batch)
      end
      assert_equal FRESH_AMOUNT, entry.reload.amount
      assert_equal original_id, posted.reload.entry.id

      # This is the migration-current -> native-retired path, complementing the
      # existing archive-only and entirely native alias-removal coverage.
      before_removal = [ entry.attributes, entry.transaction.reload.attributes ]
      removal = Provider::AccountData::Page.new(records: [], removed_ids: [ PENDING_ID ],
        complete: true, mode: "delta", coverage: { removal_policy: "exact_external_id" })
      assert_no_difference [ "Entry.count", "Transaction.count", "EntrySource.count" ] do
        publish(context, capture_page(context, removal))
      end
      assert_equal before_removal, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert_not posted.reload.withdrawn?
      assert_equal original_id, posted.entry.id
      assert_equal bootstrap_batch.id, pending.reload.entry_source.bootstrap_batch_id
    end
  end

  test "a locked amount rejects a fresh pending transition atomically and the same captured evidence can retry" do
    with_pending_bootstrap(locked_attributes: { "amount" => true }) do |context, entry, pending, bootstrap_batch|
      native_batch = capture_fresh_booked(context)
      before = [ entry.reload.attributes, entry.transaction.reload.attributes, pending.reload.attributes, pending.entry_source.attributes ]

      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Ingestion::MappedEntryResolver::Conflict) { publish(context, native_batch) }
      end

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes, pending.reload.attributes, pending.entry_source.reload.attributes ]
      assert_equal PENDING_ID, entry.external_id
      assert_equal BASELINE_AMOUNT, entry.amount
      assert pending.pending?
      assert_not pending.withdrawn?
      assert_equal bootstrap_batch.id, pending.ingestion_batch_id
      assert_not observations(context).exists?(external_id: POSTED_ID)
      assert native_batch.reload.captured?

      # The explicit local unlock is the changed permission; capture, source
      # binding and the posted provider payload are identical on retry.
      entry.unlock_attr!(:amount)
      assert_no_difference [ "Entry.count", "Transaction.count", "IngestionBatch.count" ] do
        publish(context, native_batch)
      end
      assert_equal FRESH_AMOUNT, entry.reload.amount
      assert_equal entry.id, observations(context).find_by!(external_id: POSTED_ID).entry.id
      assert native_batch.reload.applied?
    end
  end

  test "user protection survives promotion of a genuinely bootstrapped pending identity" do
    with_pending_bootstrap(user_modified: true) do |context, entry, pending, bootstrap_batch|
      original_id = entry.id

      assert_no_difference [ "Entry.count", "Transaction.count", "ProviderMerchant.count", "Category.count", "DataEnrichment.count" ] do
        publish(context, capture_fresh_booked(context))
      end

      assert_equal original_id, entry.reload.id
      assert_equal POSTED_ID, entry.external_id
      assert_equal BASELINE_AMOUNT, entry.amount
      assert_equal PENDING_DATE, entry.date
      assert_equal "Original financial description", entry.name
      assert entry.user_modified?
      assert_not entry.transaction.pending?
      assert pending.reload.withdrawn?
      assert_equal bootstrap_batch.id, pending.entry_source.bootstrap_batch_id
      assert_equal original_id, observations(context).find_by!(external_id: POSTED_ID).entry.id
    end
  end

  private
    def with_pending_bootstrap(**attributes)
      cached = { transaction_id: POSTED_ID, pending_transaction_id: PENDING_ID, pending: false,
        amount: CACHED_AMOUNT.to_s("F"), iso_currency_code: "USD", date: "2026-09-11",
        original_description: "Old cached booked description" }
      with_identity_source(provider_key: "plaid", plaid_transactions: [ cached ]) do |context|
        assert_equal CACHED_AMOUNT.to_s("F"), context.source.raw_transactions_payload.fetch("added").sole.fetch("amount")
        entry = identity_entry(context, external_id: PENDING_ID, date: PENDING_DATE, amount: BASELINE_AMOUNT,
          extra: { "plaid" => { "pending" => true } }, **attributes)
        before = identity_financial_snapshot(context)
        result = nil
        assert_no_difference [ "Entry.count", "Transaction.count", "Sync.count" ] do
          queries = capture_sql_queries do
            5.times do
              result = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family, page_size: 1).run
              break if result.verified?
            end
          end
          assert_no_financial_sql(queries)
        end
        assert result.verified?
        assert_equal before, identity_financial_snapshot(context)
        assert_equal [ PENDING_ID ], observations(context).pluck(:external_id)
        assert_not observations(context).exists?(external_id: POSTED_ID)
        pending = observations(context).sole
        batch = pending.ingestion_batch
        assert pending.pending?
        assert_not pending.withdrawn?
        assert_equal entry.id, pending.entry_source.entry_identity
        assert_equal "current", pending.entry_source.bootstrap_identity_role
        assert_equal "migration", batch.origin_kind
        assert_nil batch.sync_id
        assert_empty context.external.provider_connection.syncs
        assert_empty context.external.provider_connection.provider_sync_checkpoints.where(stream: "transactions")
        assert context.external.provider_connection.disabled?
        assert context.control.reload.quiescing?
        yield context, entry, pending, batch
      end
    end

    def observations(context)
      SourceRecord.where(external_account: context.external, kind: "transaction")
    end

    def resolver(context)
      Ingestion::MappedEntryResolver.new(external_account: context.external, account: context.account,
        definition: Provider::AccountData::Plaid.definition)
    end

    def capture_fresh_booked(context)
      raw = { "account_id" => context.external.external_id, "transaction_id" => POSTED_ID,
        "pending_transaction_id" => PENDING_ID, "pending" => false, "amount" => FRESH_AMOUNT,
        "iso_currency_code" => "USD", "date" => "2026-09-12", "original_description" => "Fresh provider description" }
      adapter = Provider::AccountData::Plaid.new(client: nil, timezone: "UTC", observed_at: Time.current,
        region: "eu", item_id: context.item.plaid_id)
      account = Ingestion::Record.account(external_id: context.external.external_id, name: "Checking", currency: "USD")
      record = adapter.normalize_transaction(raw, account: account)
      page = Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "delta", evidence: { "response" => raw })
      capture_page(context, page)
    end

    def capture_page(context, page)
      policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "transactions")
      create_provider_batch(context.external.provider_connection, external_account: context.external,
        stream: "transactions", mode: page.mode, complete: page.complete?, source_policy_version: policy.id,
        payload: Ingestion::Codec.dump(page))
    end

    def publish(context, batch)
      # This admission is local to the writer fixture. Production Plaid stays
      # gated; no connection is activated and no network client is constructed.
      Provider::AccountData::Registry.stubs(:fetch).with("plaid").returns(Provider::AccountData::Plaid)
      page = Ingestion::Codec.load(batch.reload.payload)
      context.external.provider_connection.with_lock do
        Ingestion::LedgerWriter.new(external_account: context.external, batch: batch).apply(page)
        batch.update!(status: "applied", applied_at: batch.applied_at || Time.current)
      end
    ensure
      Provider::AccountData::Registry.unstub(:fetch)
    end
end
