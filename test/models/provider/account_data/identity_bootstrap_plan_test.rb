require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::IdentityBootstrapPlanTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  Plan = Provider::AccountData::IdentityBootstrapPlan

  test "exact source identities retain every financial attribute and UUID without requiring historical raw rows" do
    with_provider_encryption do
      mapping, account, = copied_up
      entry = transaction(account, "up_stored-only", user_modified: true, import_locked: true, excluded: true,
        locked_attributes: { "name" => true }, extra: { "up" => { "pending" => false }, "private" => "private-stored-metadata" })
      expected = { "entry" => entry.reload.attributes, "entryable" => entry.entryable.reload.attributes }
      counts = [ Entry.count, Transaction.count, SourceRecord.count, EntrySource.count, IngestionBatch.count, Sync.count ]

      page = planner(mapping).page

      assert page.ready?
      assert page.complete
      row = page.document.fetch("rows").sole
      assert_equal entry.id, row.fetch("entry_id")
      assert_equal expected, Provider::AccountData::MigrationValue.decode(row.fetch("financial_snapshot"))
      assert_equal Digest::SHA256.hexdigest(Provider::AccountData::MigrationValue.dump(expected)), row.fetch("financial_checksum")
      assert_equal [], row.fetch("archive_paths")
      assert_equal "legacy_external_id", row.fetch("match_method")
      assert_equal "connection", page.document.fetch("identity_namespace")
      assert_equal mapping.external_account.account_provider.lock_version, page.document.fetch("account_provider_revision")
      assert_equal counts, [ Entry.count, Transaction.count, SourceRecord.count, EntrySource.count, IngestionBatch.count, Sync.count ]
      assert_equal expected.fetch("entry"), entry.reload.attributes
      assert page.document.frozen?
      refute_includes page.inspect, "private-stored-metadata"
    end
  end

  test "only explicit pending aliases identify the booked Entry and are separately retired" do
    with_provider_encryption do
      mapping, account, = copied_up
      entry = transaction(account, "up_booked", extra: { "up" => { "pending" => false }, "auto_claimed_pending_ids" => [ "up_pending-old", "up_pending-older" ] })
      row = planner(mapping).page.document.fetch("rows").sole
      assert_equal entry.id, row.fetch("entry_id")
      assert_equal %w[up_pending-old up_pending-older], row.fetch("pending_aliases")
      assert_equal [ "current", "retired_alias", "retired_alias" ], row.fetch("identities").map { |identity| identity.fetch("role") }
      row.fetch("identities").each do |identity|
        assert_equal identity.fetch("external_id"), identity.fetch("input_external_id")
        assert_equal 0, identity.fetch("input_occurrence")
        assert_equal false, identity.fetch("pending")
      end
    end
  end

  test "stored synthetic identities survive user edits without recomputing amount date or description hashes" do
    with_provider_encryption do
      mapping, account, = copied_up
      id = "up_pending_#{'a' * 32}"
      entry = transaction(account, id, amount: BigDecimal("999.1234"), date: Date.current - 400, name: "Edited name", user_modified: true,
        extra: { "up" => { "pending" => true } })
      row = planner(mapping).page.document.fetch("rows").sole
      assert_equal id, row.fetch("external_id")
      assert_equal true, row.fetch("pending")
      assert_equal entry.id, row.fetch("entry_id")
    end
  end

  test "Kraken ledger transactions and trade activities use their distinct resource kinds" do
    with_provider_encryption do
      mapping, account = copied_source(kraken_accounts(:one), "kraken")
      cash = transaction(account, "kraken_ledger_opaque", source: "kraken")
      trade = trade(account, "kraken_trade_opaque", source: "kraken")
      page = planner(mapping).page
      assert page.ready?
      rows = page.document.fetch("rows").index_by { |row| row.fetch("entry_id") }
      assert_equal [ "transaction", "Transaction" ], rows.fetch(cash.id).values_at("kind", "entryable_type")
      assert_equal [ "activity", "Trade" ], rows.fetch(trade.id).values_at("kind", "entryable_type")
    end
  end

  test "IBKR trade cash and commission IDs keep their existing typed financial rows" do
    with_provider_encryption do
      mapping, account = copied_source(ibkr_accounts(:main_account), "ibkr")
      entries = [ trade(account, "ibkr_trade_123", source: "ibkr"), transaction(account, "ibkr_cash_456", source: "ibkr"),
        transaction(account, "ibkr_trade_fee_123", source: "ibkr") ]
      page = planner(mapping).page
      assert page.ready?
      assert_equal entries.map(&:id).sort, page.document.fetch("rows").map { |row| row.fetch("entry_id") }.sort
      assert_equal [ "activity" ], page.document.fetch("rows").map { |row| row.fetch("kind") }.uniq
    end
  end

  test "unprefixed SnapTrade IDs use the exact source ownership and do not claim manual IDs" do
    with_provider_encryption do
      mapping, account = copied_source(snaptrade_accounts(:fidelity_401k), "snaptrade")
      owned = transaction(account, "raw-provider-id", source: "snaptrade")
      transaction(account, "raw-provider-id", source: nil)
      page = planner(mapping).page
      assert page.ready?
      assert_equal [ owned.id ], page.document.fetch("rows").map { |row| row.fetch("entry_id") }
    end
  end

  test "missing or conflicting source and malformed IDs remain visible as blockers in final inventory" do
    with_provider_encryption do
      mapping, account, = copied_up
      missing = transaction(account, nil)
      manual = transaction(account, "up_unscoped", source: nil)
      foreign = transaction(account, "up_other-source", source: "manual")
      invalid = transaction(account, "another-unreviewed-form")
      page = planner(mapping).page
      assert_not page.ready?
      assert_nil page.next_cursor
      assert_equal({ missing.id => "missing_identity", manual.id => "conflicting_source", foreign.id => "conflicting_source", invalid.id => "unreviewed_identity_form" },
        page.document.fetch("blockers").to_h { |blocker| blocker.values_at("entry_id", "code") })
      assert_equal [ missing, manual, foreign, invalid ].map(&:id).sort, planner(mapping).candidate_entry_ids
    end
  end

  test "aliases colliding with entries outside the current page stop continuation" do
    with_provider_encryption do
      mapping, account, = copied_up
      first = transaction(account, "up_booked", id: "00000000-0000-4000-8000-000000000001",
        extra: { "auto_claimed_pending_ids" => [ "up_taken" ] })
      transaction(account, "up_taken", id: "ffffffff-ffff-4fff-8fff-ffffffffffff")
      page = planner(mapping).page(limit: 1)
      assert_equal [ { "entry_id" => first.id, "code" => "identity_claimed_by_multiple_entries" } ], page.document.fetch("blockers")
      assert_nil page.next_cursor
      assert_not page.complete
    end
  end

  test "foreign provider pending flags and aliases are rejected without changing the original JSON" do
    with_provider_encryption do
      mapping, account, = copied_up
      foreign_flag = transaction(account, "up_flag", extra: { "plaid" => { "pending" => true } })
      foreign_alias = transaction(account, "up_alias", extra: { "auto_claimed_pending_ids" => [ "simplefin_alias" ] })
      malformed = transaction(account, "up_malformed", extra: { "up" => { "pending" => "true" } })
      original = [ foreign_flag, foreign_alias, malformed ].map { |entry| entry.entryable.attributes }
      page = planner(mapping).page
      assert_equal %w[foreign_pending_alias foreign_pending_state malformed_pending_state], page.document.fetch("blockers").map { |row| row.fetch("code") }.sort
      assert_equal original, [ foreign_flag, foreign_alias, malformed ].map { |entry| entry.entryable.reload.attributes }
    end
  end

  test "Lunch Flow collision families require native occurrence provenance instead of guessing API order" do
    with_provider_encryption do
      mapping, account = copied_source(lunchflow_accounts(:investment_account), "lunchflow")
      base = "lunchflow_pending_#{'b' * 32}"
      transaction(account, base, source: "lunchflow", extra: { "lunchflow" => { "pending" => true } })
      transaction(account, "#{base}_1", source: "lunchflow", extra: { "lunchflow" => { "pending" => true } })
      page = planner(mapping).page
      assert_equal [ "unresolved_input_occurrence" ] * 2, page.document.fetch("blockers").map { |row| row.fetch("code") }
      assert_empty page.document.fetch("rows")
    end
  end

  test "pages and public final inventory share deterministic UUID enumeration and exact revision binding" do
    with_provider_encryption do
      mapping, account, = copied_up
      3.times { |index| transaction(account, "up_#{index}") }
      plan = planner(mapping)
      first = plan.page(limit: 1)
      second = plan.page(cursor: first.next_cursor, limit: 1)
      third = plan.page(cursor: second.next_cursor, limit: 1)
      ids = [ first, second, third ].flat_map { |page| page.document.fetch("rows").map { |row| row.fetch("entry_id") } }
      assert_equal ids, plan.candidate_entry_ids
      assert_equal ids.drop(1), plan.candidate_entry_ids(after_id: ids.first)
      assert third.complete
      mapping.external_account.account_provider.touch
      assert_raises(Plan::InvalidContext) { plan.page(cursor: first.next_cursor, limit: 1) }
    end
  end

  test "current legacy cache changes invalidate the copied archive before financial planning" do
    with_provider_encryption do
      mapping, account, source = copied_up
      entry = transaction(account, "up_original")
      source.update!(raw_transactions_payload: [ { "id" => "new-cache-content" } ])
      assert_raises(Plan::InvalidContext) { planner(mapping).page }
      assert_raises(Plan::InvalidContext) { planner(mapping).candidate_entry_ids }
      assert_equal "up_original", entry.reload.external_id
    end
  end

  test "other family unverified copy native eligibility and namespace changes cannot produce a plan" do
    with_provider_encryption do
      mapping, = copied_up
      assert_raises(Plan::InvalidContext) { Plan.new(mapping: mapping, family: families(:empty)).page }
      mapping.update!(verified_at: nil)
      assert_raises(Plan::InvalidContext) { planner(mapping).page }
      mapping.update!(verified_at: Time.current)
      mapping.external_account.provider_connection.update!(status: "good")
      assert_raises(Plan::InvalidContext) { planner(mapping).page }
      mapping.external_account.provider_connection.update!(status: "disabled")
      mapping.external_account.update_columns(identity_namespace: "another-namespace")
      assert_raises(Plan::InvalidContext) { planner(mapping).page }
    end
  end

  test "existing source evidence cannot be repointed to another Entry UUID" do
    with_provider_encryption do
      mapping, account, = copied_up
      entry = transaction(account, "up_original")
      other = transaction(account, "up_another")
      external = mapping.external_account
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions")
      record = SourceRecord.create!(family: account.family, account: account, external_account: external, ingestion_batch: batch,
        kind: "transaction", external_id: entry.external_id)
      record.create_entry_source!(family: account.family, account: account, entry: other, role: "posting", match_method: "provider_reconciliation")
      page = planner(mapping).page
      assert_equal [ { "entry_id" => entry.id, "code" => "conflicting_native_evidence" } ], page.document.fetch("blockers")
      assert_equal other.id, record.reload.entry_source.entry_id
    end
  end

  test "financial payload preflight bounds run before loading Entry objects and page sizes are bounded" do
    with_provider_encryption do
      mapping, account, = copied_up
      transaction(account, "up_large", extra: { "private" => "a" * 2048 })
      previous = Plan::MAX_FINANCIAL_BYTES
      Plan.send(:remove_const, :MAX_FINANCIAL_BYTES)
      Plan.const_set(:MAX_FINANCIAL_BYTES, 1)
      Entry.any_instance.expects(:entryable).never
      assert_raises(Plan::InvalidContext) { planner(mapping).page }
      assert_raises(ArgumentError) { planner(mapping).page(limit: 0) }
      assert_raises(ArgumentError) { planner(mapping).candidate_entry_ids(limit: 501) }
    ensure
      Plan.send(:remove_const, :MAX_FINANCIAL_BYTES)
      Plan.const_set(:MAX_FINANCIAL_BYTES, previous)
    end
  end

  test "an entryable shared with another account is rejected before repeated financial snapshots are loaded" do
    with_provider_encryption do
      mapping, account, = copied_up
      entry = transaction(account, "up_shared", extra: { "large" => "a" * 2048 })
      other_account = families(:empty).accounts.create!(name: "Separate family", currency: "USD", balance: 0, accountable: Depository.new)
      other = transaction(other_account, "up_other-family")
      other.update_columns(entryable_id: entry.entryable_id)

      Entry.any_instance.expects(:entryable).never
      assert_raises(Plan::InvalidContext) { planner(mapping).page }
      assert_equal entry.entryable_id, other.reload.entryable_id
    end
  end

  private
    def copied_up
      item = UpItem.create!(family: families(:dylan_family), name: "Identity copy", access_token: "private-token")
      source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Source account", currency: "USD", raw_transactions_payload: [])
      [ *copied_source(source, "up"), source ]
    end

    def copied_source(source, provider_key)
      manifest = Provider::AccountData::MigrationManifest.for(provider_key)
      item = source.public_send(provider_key + "_item")
      account = item.family.accounts.create!(name: "Financial identity test", currency: "USD", balance: BigDecimal("1000.1234"), accountable: Depository.new)
      AccountProvider.create!(account: account, provider: source)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: provider_key, legacy_item_id: item.id)
      20.times do
        copier.run
        break if copier.control.reload.shadow?
      end
      assert copier.control.shadow?
      mapping = copier.control.provider_migration_mappings.find_by!(role: "external_account", legacy_type: manifest.account_type, legacy_id: source.id)
      [ mapping, account ]
    end

    def planner(mapping)
      Plan.new(mapping: mapping, family: families(:dylan_family))
    end

    def transaction(account, id, source: "up", extra: nil, **attributes)
      account.entries.create!({ name: "Original description", external_id: id, source: source, currency: "USD", amount: BigDecimal("12.3456"),
        date: Date.current, entryable: Transaction.new(extra: extra) }.merge(attributes))
    end

    def trade(account, id, source:)
      account.entries.create!(name: "Original trade", external_id: id, source: source, currency: "USD", amount: BigDecimal("12.3456"), date: Date.current,
        entryable: Trade.new(security: securities(:aapl), qty: BigDecimal("1.2345"), price: BigDecimal("10.0001"), currency: "USD"))
    end
end
