require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::UnpublishedObservationsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "retaining a later observation cannot edit an existing financial target or its published evidence" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      original = page([ record("existing-financial-target", "12.34") ])
      batch = create_provider_batch(connection, external_account: external, stream: "transactions",
        scope_key: "account:#{external.id}", source_policy_version: policy.id, payload: Ingestion::Codec.dump(original))
      Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(original)
      observation = SourceRecord.find_by!(external_account: external, external_id: "existing-financial-target")
      entry = observation.entry
      external.update!(status: "ignored")
      generation = retain(external, [ record("existing-financial-target", "99.99") ])
      assert generation.applied?
      assert_equal BigDecimal("12.34"), entry.reload.amount
      assert_equal batch.id, observation.reload.ingestion_batch_id
      assert_equal account.id, observation.account_id
      assert_equal entry.id, observation.entry.id
      assert external.reload.transaction_backfill_required?
      assert_equal BigDecimal("99.99"), Ingestion::Codec.load(generation.children.sole.payload).records.sole[:amount]
    end
  end

  test "retained source order prevents an older pending observation from replacing a posted revision" do
    with_provider_encryption do
      external = create_external_account(create_provider_connection)
      retain(external, [ record("ordered-observation", "12.34", order: [ 2 ], pending: false) ])
      observation = SourceRecord.find_by!(external_account: external, external_id: "ordered-observation")
      posted_batch_id = observation.ingestion_batch_id
      retain(external, [ record("ordered-observation", "12.34", order: [ 1 ], pending: true) ])
      assert_not observation.reload.pending?
      assert_equal [ 2 ], observation.observation_order
      assert_equal posted_batch_id, observation.ingestion_batch_id
      assert_nil observation.account_id
      assert_empty observation.entry_sources
    end
  end

  test "a regular provider page cannot bypass generation review by using the unpublished writer" do
    with_provider_encryption do
      external = create_external_account(create_provider_connection)
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions")
      assert_no_difference "SourceRecord.count" do
        assert_raises(Provider::AccountData::InvalidResponse) do
          Ingestion::UnpublishedObservations.new(external_account: external, batch: batch).apply(page([ record("not-sealed", "1") ]))
        end
      end
    end
  end

  private
    def record(id, amount, order: [], pending: false)
      Ingestion::Record.transaction(external_id: id, name: "Observed purchase", amount: BigDecimal(amount), currency: "USD",
        date: Date.current, pending: pending, metadata: { observation_order: order })
    end

    def page(records)
      Provider::AccountData::Page.new(records: records, complete: true, mode: "delta",
        coverage: { "removal_policy" => "exact_external_id", "pending_absence_authoritative" => false })
    end

    def retain(external, records)
      partial = Provider::AccountData::Page.new(records: records, complete: false, mode: "delta")
      external_id = external.external_id
      adapter = Object.new
      adapter.define_singleton_method(:fetch_transaction_group) do |generation_id:, start_cursor:, cursor:|
        Provider::AccountData::TransactionGroup.new(generation_id: generation_id, start_cursor: start_cursor, request_cursor: cursor,
          next_cursor: "terminal-#{generation_id}", complete: true, account_pages: { external_id => partial }, unassigned_removed_ids: [], evidence: {})
      end
      connection = external.provider_connection
      Provider::AccountData::TransactionSync.new(connection: connection, sync: connection.syncs.create!, adapter: adapter,
        writer_epoch: connection.writer_epoch, fence: ->(&block) { connection.with_lock(&block) }).perform
    end
end
