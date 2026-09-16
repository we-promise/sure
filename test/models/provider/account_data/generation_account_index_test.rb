require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::GenerationAccountIndexTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Index = Provider::AccountData::GenerationAccountIndex

  test "the projection includes retained accounts and distinguishes verified unlinked records" do
    first, second = Array.new(2) { SecureRandom.uuid }
    context = snapshot(first, second, first, nil)
    context.fetch("accounts").values[1]["publication"] = "retained"
    context.fetch("accounts").values[1]["source_policy_version"] = nil
    expected = [ first, second ].map(&:dup).sort

    projection = Index.capture_ids(context_snapshot: context, stream: "transactions")
    assert_equal expected, projection
    assert projection.frozen?
    assert projection.all?(&:frozen?)
    context.fetch("accounts").values.first.fetch("account_id").replace(SecureRandom.uuid)
    assert_equal expected, projection
    assert_equal [], Index.capture_ids(context_snapshot: snapshot(nil), stream: "transactions")
    assert_equal [], Index.capture_ids(context_snapshot: snapshot, stream: "activities")
  end

  test "missing malformed or contradictory original bindings cannot become an empty projection" do
    originals = [ {}, { "version" => 1 }, { "version" => 2, "accounts" => {} },
      { "version" => 1, "accounts" => [] } ]
    originals << snapshot(SecureRandom.uuid).tap { |context| context["accounts"].values.first["account_id"] = "private-invalid-id" }
    originals << snapshot(SecureRandom.uuid).tap { |context| context["accounts"].values.first["account_provider_id"] = nil }
    originals << snapshot(nil).tap { |context| context["accounts"].values.first["publication"] = "ledger" }
    originals << snapshot(SecureRandom.uuid, resource: "activities")

    originals.each do |context|
      error = assert_raises(Index::Conflict) { Index.capture_ids(context_snapshot: context, stream: "transactions") }
      refute_includes error.message, "private-invalid-id"
    end
  end

  test "original bindings cannot duplicate external account ownership" do
    context = snapshot(SecureRandom.uuid, SecureRandom.uuid)
    context["accounts"].values.last["external_account_id"] = context["accounts"].values.first["external_account_id"]
    assert_raises(Index::Conflict) { Index.capture_ids(context_snapshot: context, stream: "transactions") }
  end

  test "oversized original maps fail instead of silently truncating the ownership inventory" do
    binding = snapshot(nil).fetch("accounts").values.first
    context = { "version" => 1, "accounts" => (Index::MAX_ACCOUNTS + 1).times.to_h do |i|
      [ "upstream-#{i}", binding.merge("external_account_id" => SecureRandom.uuid) ]
    end }

    assert_raises(Index::Conflict) { Index.capture_ids(context_snapshot: context, stream: "transactions") }
  end

  test "excessive context depth is rejected before encoding a captured projection" do
    context = snapshot
    nested = context
    (Index::MAX_DEPTH + 1).times { nested = nested["nested"] = {} }

    assert_raises(Index::Conflict) { Index.capture_ids(context_snapshot: context, stream: "transactions") }
  end

  test "historical UUIDs remain discoverable with no current financial account or provider link" do
    with_provider_encryption do
      connection = create_provider_connection
      historical_id = SecureRandom.uuid
      original = snapshot(historical_id)
      row = generation(connection, original, account_ids: [ historical_id ])
      historical = Account.new(id: historical_id, family_id: connection.family_id)

      assert_nil Account.find_by(id: historical_id)
      assert_equal [ row.id ], Index.for_account(historical).pluck(:id)
      assert_equal [ historical_id ], Index.verify!(generation: row)
      assert_provider_column_encrypted(row, :context_snapshot, original["accounts"].keys.first)
      assert_empty Index.for_account(Account.new(id: historical_id, family_id: families(:empty).id))
    end
  end

  test "unknown and verified empty generations have different completeness semantics" do
    with_provider_encryption do
      connection = create_provider_connection(family: families(:empty))
      unknown = generation(connection, snapshot)

      assert_nil unknown.account_ids
      assert_raises(Index::Incomplete) { Index.assert_complete_for!(family_id: connection.family_id) }
      assert_raises(Index::Conflict) { Index.verify!(generation: unknown) }
      unknown.delete

      verified = generation(connection, snapshot, account_ids: [])
      assert_equal [], Index.verify!(generation: verified)
      assert Index.assert_complete_for!(family_id: connection.family_id)
    end
  end

  test "integrity verification rejects a false initial projection even when completeness passes" do
    with_provider_encryption do
      connection = create_provider_connection(family: families(:empty))
      row = connection.provider_sync_generations.build(sync: connection.syncs.create!, writer_epoch: 0,
        context_snapshot: snapshot(SecureRandom.uuid), account_ids: [], status: "abandoned")
      refute row.valid?
      assert row.errors[:account_ids].present?
      # PostgreSQL cannot decrypt application-encrypted context. INSERT shape
      # guards cannot establish equality with the original captured map.
      row.save!(validate: false)

      assert Index.assert_complete_for!(family_id: connection.family_id)
      assert_raises(Index::Conflict) { Index.verify!(generation: row) }
    end
  end

  test "verification reloads captured identity rather than trusting caller changes" do
    with_provider_encryption do
      connection = create_provider_connection
      id = SecureRandom.uuid
      row = generation(connection, snapshot(id), account_ids: [ id ])
      row.assign_attributes(family_id: families(:empty).id)

      assert_raises(Index::Conflict) { Index.verify!(generation: row) }
      assert_equal [ id ], Index.verify!(generation: row.reload)
    end
  end

  test "database guards preserve the original capture and completed projection through raw updates" do
    with_provider_encryption do
      connection = create_provider_connection
      id = SecureRandom.uuid
      row = generation(connection, snapshot(id), account_ids: [ id ])
      [ { account_ids: [] }, { account_ids: nil }, { context_snapshot: snapshot },
        { start_cursor: "private-replacement" }, { writer_epoch: 1 } ].each do |change|
        assert_raises(ActiveRecord::StatementInvalid) do
          ApplicationRecord.transaction(requires_new: true) { row.update_columns(change) }
        end
        row.reload
      end

      assert_equal [ id ], Index.verify!(generation: row)
    end
  end

  private
    def snapshot(*account_ids, resource: "transactions")
      { "version" => 1, "accounts" => account_ids.each_with_index.to_h do |account_id, i|
        [ "upstream-#{i}", {
          "external_account_id" => SecureRandom.uuid, "status" => "active", "resource" => resource,
          "identity_namespace" => "connection", "account_id" => account_id,
          "account_provider_id" => account_id && SecureRandom.uuid,
          "account_currency" => account_id && "USD", "accountable_type" => account_id && "Depository",
          "accountable_id" => account_id && SecureRandom.uuid,
          "account_provider_revision" => account_id && 0, "publication" => account_id ? "ledger" : "retained",
          "source_policy_version" => account_id && SecureRandom.uuid, "authorizations" => []
        } ]
      end }
    end

    def generation(connection, context, **attributes)
      connection.provider_sync_generations.create!({ sync: connection.syncs.create!, writer_epoch: 0,
        context_snapshot: context, status: "abandoned" }.merge(attributes))
    end
end
