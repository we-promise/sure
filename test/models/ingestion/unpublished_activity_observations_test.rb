require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::UnpublishedActivityObservationsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "unlinked activity identities are retained without financial publication or pending state" do
    with_provider_encryption do
      external = create_external_account(create_provider_connection)
      page, batch = retained_batch(external, [ activity("activity-one", "12") ])

      assert_no_difference [ "Entry.count", "Trade.count", "Transaction.count", "EntrySource.count" ] do
        Ingestion::UnpublishedObservations.new(external_account: external, batch: batch).apply(page)
      end
      observation = SourceRecord.find_by!(external_account: external, kind: "activity", external_id: "activity-one")
      assert_nil observation.account_id
      assert_equal batch.id, observation.ingestion_batch_id
      assert_not observation.pending?
      assert_not observation.withdrawn?
      assert_empty observation.entry_sources
      assert_no_difference "SourceRecord.count" do
        Ingestion::UnpublishedObservations.new(external_account: external, batch: batch).apply(page)
      end
    end
  end

  test "retained activity observations preserve ordering without modifying an earlier published source" do
    with_provider_encryption do
      external = create_external_account(create_provider_connection)
      first, batch = retained_batch(external, [ activity("ordered", "12", observation_order: [ 2 ]) ])
      Ingestion::UnpublishedObservations.new(external_account: external, batch: batch).apply(first)
      finish_generation(batch)
      observation = SourceRecord.find_by!(external_account: external, kind: "activity", external_id: "ordered")
      older, older_batch = retained_batch(external, [ activity("ordered", "9", observation_order: [ 1 ]) ])
      Ingestion::UnpublishedObservations.new(external_account: external, batch: older_batch).apply(older)
      finish_generation(older_batch)
      assert_equal batch.id, observation.reload.ingestion_batch_id
      assert_equal [ 2 ], observation.observation_order

      account = accounts(:investment)
      link = AccountProvider.create!(account: account, external_account: external)
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "activities")
      publication = create_provider_batch(external.provider_connection, external_account: external, stream: "activities",
        source_policy_version: policy.id, scope_key: "account:#{external.id}")
      observation.update!(account: account, ingestion_batch: publication)
      before = observation.reload.attributes
      later, later_batch = retained_batch(external, [ activity("ordered", "99", observation_order: [ 3 ]) ])

      assert_no_difference [ "Entry.count", "EntrySource.count" ] do
        Ingestion::UnpublishedObservations.new(external_account: external, batch: later_batch).apply(later)
      end
      assert_equal before, observation.reload.attributes
    end
  end

  test "activity retention rejects transaction values removals and absence authority before writing" do
    with_provider_encryption do
      external = create_external_account(create_provider_connection)
      _page, batch = retained_batch(external, [])
      transaction = Ingestion::Record.transaction(external_id: "transaction", name: "Transaction", currency: "USD",
        date: Date.current, amount: BigDecimal("12"), pending: false)
      invalid = [
        Provider::AccountData::Page.new(records: [ transaction ], complete: true, coverage: { "pending_absence_authoritative" => false }),
        Provider::AccountData::Page.new(records: [], removed_ids: [ "removed" ], complete: true, coverage: { "pending_absence_authoritative" => false }),
        Provider::AccountData::Page.new(records: [], complete: true, coverage: { "pending_absence_authoritative" => true }),
        Provider::AccountData::Page.new(records: [], complete: true, coverage: { "pending_absence_authoritative" => false, "removal_policy" => "exact_external_id" })
      ]
      assert_no_difference "SourceRecord.count" do
        invalid.each do |page|
          assert_raises(Provider::AccountData::InvalidResponse) do
            Ingestion::UnpublishedObservations.new(external_account: external, batch: batch).apply(page)
          end
        end
      end
    end
  end

  private
    def activity(id, amount, **metadata)
      Ingestion::Record.activity(external_id: id, name: "Observed dividend", amount: BigDecimal(amount), currency: "USD",
        date: Date.current, activity_type: "dividend", metadata: metadata)
    end

    def retained_batch(external, records)
      connection = external.provider_connection
      sync = connection.syncs.create!
      generation = connection.provider_sync_generations.create!(sync: sync, stream: "activities", scope_key: "connection",
        writer_epoch: connection.writer_epoch, context_snapshot: { "accounts" => { external.external_id => { "publication" => "retained" } } })
      group = Provider::AccountData::TransactionGroup.new(resource: "activities", folding_policy: "first_observation",
        generation_id: generation.id, start_cursor: nil, request_cursor: nil, next_cursor: "terminal", complete: true,
        account_pages: { external.external_id => Provider::AccountData::Page.new(records: records, complete: false) }, unassigned_removed_ids: [], evidence: {})
      page = Ingestion::TransactionGroupAssembler.new.assemble([ group ]).fetch(external.external_id)
      create_provider_batch(connection, sync: sync, stream: "activity_groups", scope_key: "connection", provider_sync_generation: generation,
        generation_role: "page", payload: Ingestion::TransactionGroupCodec.dump(group))
      batch = create_provider_batch(connection, sync: sync, stream: "activities", scope_key: "account:#{external.id}", external_account: external,
        provider_sync_generation: generation, generation_role: "account", payload: Ingestion::Codec.dump(page), coverage: page.coverage, mode: "delta")
      generation.update!(status: "sealed", terminal_cursor: "terminal", page_count: 1, child_count: 1, sealed_at: Time.current)
      batch.association(:provider_sync_generation).target = generation
      [ page, batch ]
    end

    def finish_generation(batch)
      generation = batch.provider_sync_generation
      generation.ingestion_batches.each { |captured| captured.update!(status: "applied", applied_at: Time.current) }
      generation.update!(status: "applied", applied_at: Time.current)
    end
end
