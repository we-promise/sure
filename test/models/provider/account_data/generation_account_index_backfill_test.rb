require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::GenerationAccountIndexBackfillTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Index = Provider::AccountData::GenerationAccountIndex

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "bounded keyset backfill preserves original encrypted captures and unrelated state" do
    with_connection do |connection|
      ids = Array.new(3) { SecureRandom.uuid }.sort
      rows = ids.map { |id| generation(connection, id: id) }
      before = rows.to_h { |row| [ row.id, row.attributes.except("account_ids") ] }
      ciphertexts = raw_contexts(connection)
      first = Index.backfill_page(family_id: connection.family_id, limit: 2)

      assert_equal 2, first.processed
      refute first.complete
      assert_equal ids[1], first.next_cursor
      assert_nil rows.last.reload.account_ids
      assert_raises(Index::Incomplete) { Index.assert_complete_for!(family_id: connection.family_id) }
      second = Index.backfill_page(family_id: connection.family_id, after_id: first.next_cursor, limit: 2)

      assert_equal 1, second.processed
      assert second.complete
      assert_nil second.next_cursor
      assert Index.assert_complete_for!(family_id: connection.family_id)
      rows.each do |row|
        assert_equal [], Index.verify!(generation: row.reload)
        assert_equal before.fetch(row.id), row.attributes.except("account_ids")
      end
      assert_equal ciphertexts, raw_contexts(connection)
      assert_equal 0, Index.backfill_page(family_id: connection.family_id).processed
      assert connection.reload.disabled?
      assert_empty connection.external_accounts
      assert_empty connection.ingestion_batches
    end
  end

  test "one malformed original stops the page without rolling back already committed projections" do
    with_connection do |connection|
      ids = Array.new(3) { SecureRandom.uuid }.sort
      first = generation(connection, id: ids[0])
      bad = generation(connection, id: ids[1], context_snapshot: { "private" => "invalid-original" })
      last = generation(connection, id: ids[2])
      ciphertexts = raw_contexts(connection)

      error = assert_raises(Index::Conflict) { Index.backfill_page(family_id: connection.family_id, limit: 3) }
      refute_includes error.message, "invalid-original"
      assert_equal [], first.reload.account_ids
      assert_nil bad.reload.account_ids
      assert_nil last.reload.account_ids
      assert_equal ciphertexts, raw_contexts(connection)
      assert_raises(Index::Conflict) { Index.backfill_page(family_id: connection.family_id, limit: 3) }
      assert_raises(Index::Incomplete) { Index.assert_complete_for!(family_id: connection.family_id) }
    end
  end

  test "a cursor is traversal progress and cannot conceal earlier unresolved generations" do
    with_connection do |connection|
      ids = Array.new(2) { SecureRandom.uuid }.sort
      unknown = generation(connection, id: ids[0], context_snapshot: {})
      generation(connection, id: ids[1])
      page = Index.backfill_page(family_id: connection.family_id, after_id: unknown.id)

      assert page.complete
      assert_equal 1, page.processed
      assert_raises(Index::Incomplete) { Index.assert_complete_for!(family_id: connection.family_id) }
      # This family's old captures must not make another family's inventory fail.
      assert Index.assert_complete_for!(family_id: families(:empty).id)
    end
  end

  test "backfill refuses an outer transaction and invalid pagination before updating rows" do
    with_connection do |connection|
      row = generation(connection)
      ApplicationRecord.transaction do
        assert_raises(Index::Conflict) { Index.backfill_page(family_id: connection.family_id) }
      end
      [ 0, 101, "2" ].each do |limit|
        assert_raises(ArgumentError) { Index.backfill_page(family_id: connection.family_id, limit: limit) }
      end
      assert_raises(ArgumentError) { Index.backfill_page(family_id: connection.family_id, after_id: "not-a-uuid") }
      assert_nil row.reload.account_ids
    end
  end

  private
    def with_connection
      with_provider_encryption do
        family = Family.create!(name: "Generation account index")
        connection = create_provider_connection(family: family, status: "disabled")
        yield connection
      ensure
        if connection&.persisted?
          connection.provider_sync_generations.delete_all
          connection.syncs.delete_all
          connection.destroy!
        end
        family&.destroy! if family&.persisted?
        clear_enqueued_jobs
      end
    end

    def generation(connection, **attributes)
      connection.provider_sync_generations.create!({ sync: connection.syncs.create!, writer_epoch: 0,
        status: "abandoned", context_snapshot: { "version" => 1, "accounts" => {} } }.merge(attributes))
    end

    def raw_contexts(connection)
      scope = connection.provider_sync_generations.order(:id).select(:id, :context_snapshot)
      ApplicationRecord.connection.select_rows(scope.to_sql)
    end
end
