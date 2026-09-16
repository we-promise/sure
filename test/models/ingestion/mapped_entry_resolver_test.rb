require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::MappedEntryResolverTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Resolver = Ingestion::MappedEntryResolver

  test "resolves the reviewed UUID without changing protected financial or identity fields" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "booked", source: "plaid", user_modified: true, excluded: true, import_locked: true)
      observation = observed(external, "booked", entry: entry)
      before = [ entry.attributes, entry.transaction.attributes ]

      result = nil
      assert_no_difference [ "Entry.count", "Transaction.count", "EntrySource.count", "IngestionBatch.count", "DataEnrichment.count" ] do
        result = resolve(external, observation)
      end

      assert result.resolved?
      assert_equal entry.id, result.entry.id
      assert_equal entry.id, result.entry_identity
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      refute_includes result.inspect, "booked"
    end
  end

  test "an explicit legacy plaid_id mapping adopts the UUID without backfilling Entry columns" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(plaid_id: "older")
      observation = observed(external, "older", entry: entry, match_method: "legacy_plaid_id")

      result = resolve(external, observation)

      assert result.resolved?
      assert_equal entry.id, result.entry.id
      assert_nil entry.reload.external_id
      assert_nil entry.source
      assert_equal "older", entry.plaid_id
    end
  end

  test "a plaid_id without an explicit reviewed mapping cannot become a generic fallback" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(plaid_id: "older")
      observation = observed(external, "older", entry: entry)
      assert_raises(Resolver::Conflict) { resolve(external, observation) }
    end
  end

  test "retired pending replay returns suppression with no writable Entry" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "booked", source: "plaid", extra: {
        "plaid" => { "pending" => false }, "auto_claimed_pending_ids" => [ "pending" ]
      })
      observation = observed(external, "pending", entry: entry)

      result = resolve(external, observation)

      assert result.retired_alias?
      assert_nil result.entry
      assert_equal entry.id, result.entry_identity
      assert_equal "booked", result.current_external_id
      assert_equal false, entry.transaction.reload.extra.dig("plaid", "pending")
    end
  end

  test "Plaid's explicit booked pending link also identifies a retired alias" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "booked", source: "plaid", extra: {
        "plaid" => { "pending" => false, "pending_transaction_id" => "pending" }
      })
      assert resolve(external, observed(external, "pending", entry: entry)).retired_alias?
    end
  end

  test "an explicit pending transition is a read-only typed result for the same UUID" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "pending", source: "plaid", extra: { "plaid" => { "pending" => true } })
      observation = observed(external, "pending", entry: entry, pending: true)
      before = [ entry.attributes, entry.transaction.attributes, observation.attributes ]
      result = Resolver.new(external_account: external, account: accounts(:depository), definition: Provider::AccountData::Plaid.definition)
        .resolve_pending_transition(source_record: observation, pending_external_id: "pending", posted_external_id: "posted")

      assert result.pending_transition?
      assert_equal entry.id, result.entry_identity
      assert_equal "posted", result.external_id
      assert_equal "pending", result.previous_external_id
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes, observation.reload.attributes ]
    end
  end

  test "an explicit pending link cannot claim a posted observation or a second existing UUID" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "pending", source: "plaid", extra: { "plaid" => { "pending" => true } })
      observation = observed(external, "pending", entry: entry)
      resolver = Resolver.new(external_account: external, account: accounts(:depository), definition: Provider::AccountData::Plaid.definition)
      assert_raises(Resolver::Conflict) { resolver.resolve_pending_transition(source_record: observation, pending_external_id: "pending", posted_external_id: "posted") }
      observation.update!(pending: true)
      financial_entry(external_id: "posted", source: "plaid")
      assert_raises(Resolver::Conflict) { resolver.resolve_pending_transition(source_record: observation, pending_external_id: "pending", posted_external_id: "posted") }
    end
  end

  test "an observation with no mapping is explicit and never matched by financial resemblance" do
    with_provider_encryption do
      external = linked_plaid
      financial_entry
      result = resolve(external, observed(external, "unmapped"))
      assert result.unmapped?
      assert_nil result.entry
      assert_nil result.entry_identity
    end
  end

  test "a competing external ID rejects adoption even when the mapped UUID is protected" do
    with_provider_encryption do
      external = linked_plaid
      legacy = financial_entry(plaid_id: "collision", user_modified: true)
      competing = financial_entry(external_id: "collision", source: "plaid")
      observation = observed(external, "collision", entry: legacy, match_method: "legacy_plaid_id")
      assert_raises(Resolver::Conflict) { resolve(external, observation) }
      assert legacy.reload.persisted?
      assert competing.reload.persisted?
    end
  end

  test "a second legacy plaid_id cannot be hidden by a valid current external ID mapping" do
    with_provider_encryption do
      external = linked_plaid
      current = financial_entry(external_id: "duplicate", source: "plaid")
      financial_entry(plaid_id: "duplicate")
      observation = observed(external, "duplicate", entry: current)
      assert_raises(Resolver::Conflict) { resolve(external, observation) }
    end
  end

  test "a protected Trade resolves as an activity without changing quantity price or amount" do
    with_provider_encryption do
      external = linked_plaid(account: accounts(:investment))
      entry = entries(:trade)
      entry.update!(source: "plaid", external_id: "trade", user_modified: true)
      observation = observed(external, "trade", entry: entry, kind: "activity")
      before = [ entry.reload.attributes, entry.trade.reload.attributes ]

      result = Resolver.new(external_account: external, account: accounts(:investment), definition: Provider::AccountData::Plaid.definition)
        .resolve(source_record: observation, kind: "activity", external_id: "trade", entryable_type: "Trade")

      assert result.resolved?
      assert_equal entry.id, result.entry.id
      assert_equal before, [ entry.reload.attributes, entry.trade.reload.attributes ]
    end
  end

  test "mismatched financial type or source is rejected before an importer is invoked" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "activity", source: "plaid")
      observation = observed(external, "activity", entry: entry, kind: "activity")
      assert_raises(Resolver::Conflict) { resolve(external, observation, entryable_type: "Trade") }
      entry.update!(source: "up")
      assert_raises(Resolver::Conflict) { resolve(external, observation) }
    end
  end

  test "changed account or foreign provider and family cannot reuse a mapping" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "original", source: "plaid")
      observation = observed(external, "original", entry: entry)
      assert_raises(Resolver::Conflict) do
        Resolver.new(external_account: external, account: accounts(:investment), definition: Provider::AccountData::Plaid.definition)
          .resolve(source_record: observation, kind: "transaction", external_id: "original", entryable_type: "Transaction")
      end
      other_connection = create_provider_connection(provider_key: "plaid", family: families(:empty))
      foreign = create_external_account(other_connection)
      assert_raises(Resolver::Conflict) { resolve(foreign, observation) }
      assert_raises(Resolver::Conflict) do
        Resolver.new(external_account: external, account: accounts(:depository), definition: Provider::AccountData::Up.definition)
          .resolve(source_record: observation, kind: "transaction", external_id: "original", entryable_type: "Transaction")
      end
    end
  end

  test "corroborating evidence is not permission to adopt another posting" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "evidence", source: "plaid")
      observation = observed(external, "evidence", entry: entry, role: "evidence")
      assert_raises(Resolver::Conflict) { resolve(external, observation) }
    end
  end

  test "archived evidence retains the deleted UUID and cannot fall through to new insertion" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "deleted", source: "plaid")
      observation = observed(external, "deleted", entry: entry)
      original_id = entry.id
      entry.destroy!

      assert_raises(Resolver::Conflict) { resolve(external, observation) }
      assert_equal original_id, observation.entry_sources.sole.entry_identity
      assert_nil observation.entry_sources.sole.entry_id
    end
  end

  test "a malformed retained UUID cannot be persisted against the current entry FK" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "mismatch", source: "plaid")
      assert_raises(ActiveRecord::RecordInvalid) do
        observed(external, "mismatch", entry: entry, entry_identity: SecureRandom.uuid)
      end
    end
  end

  test "a different requested provider ID cannot use an otherwise valid SourceRecord" do
    with_provider_encryption do
      external = linked_plaid
      entry = financial_entry(external_id: "exact", source: "plaid")
      observation = observed(external, "exact", entry: entry)
      assert_raises(Resolver::Conflict) do
        Resolver.new(external_account: external, account: accounts(:depository), definition: Provider::AccountData::Plaid.definition)
          .resolve(source_record: observation, kind: "transaction", external_id: "guessed", entryable_type: "Transaction")
      end
    end
  end

  private
    def linked_plaid(account: accounts(:depository))
      connection = create_provider_connection(provider_key: "plaid")
      external = create_external_account(connection)
      AccountProvider.create!(account: account, external_account: external)
      external
    end

    def financial_entry(extra: {}, **attributes)
      accounts(:depository).entries.create!({ name: "Preserve my edit", date: Date.current, amount: 32, currency: "USD",
        entryable: Transaction.new(extra: extra) }.merge(attributes))
    end

    def observed(external, id, entry: nil, match_method: "provider_reconciliation", role: "posting", kind: "transaction", entry_identity: nil, pending: false)
      attributes = { external_id: id, name: "Observed transaction", date: Date.current, amount: BigDecimal("32"), currency: "USD" }
      record = if kind == "transaction"
        Ingestion::Record.transaction(**attributes, pending: pending)
      elsif entry&.trade?
        Ingestion::Record.activity(**attributes, activity_type: "buy", ledger_type: "trade", quantity: entry.trade.qty,
          price: entry.trade.price, security: { ticker: entry.trade.security.ticker })
      else
        Ingestion::Record.activity(**attributes, activity_type: "fee", ledger_type: "transaction")
      end
      page = Provider::AccountData::Page.new(records: [ record ], complete: true)
      batch = create_provider_batch(external.provider_connection, external_account: external,
        stream: kind == "transaction" ? "transactions" : "activities", payload: Ingestion::Codec.dump(page))
      observation = SourceRecord.create!(external_account: external, account: external.current_account, family: families(:dylan_family),
        ingestion_batch: batch, kind: kind, external_id: id, pending: pending)
      if entry
        observation.create_entry_source!(entry: entry, entry_identity: entry_identity, account: external.current_account,
          family: families(:dylan_family), role: role, match_method: match_method)
      end
      observation
    end

    def resolve(external, observation, entryable_type: "Transaction")
      Resolver.new(external_account: external, account: accounts(:depository), definition: Provider::AccountData::Plaid.definition)
        .resolve(source_record: observation, kind: observation.kind, external_id: observation.external_id, entryable_type: entryable_type)
    end
end
