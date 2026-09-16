require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Plaid::IdentityBootstrapPlanTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Plan = Provider::AccountData::Plaid::IdentityBootstrapPlan

  test "read-only plan retains exact financial state and both Plaid identity generations" do
    with_provider_encryption do
      legacy = transaction(plaid_id: "old-id", extra: { "plaid" => { "pending" => false } },
        user_modified: true, import_locked: true, excluded: true, locked_attributes: { "name" => true })
      modern = transaction(external_id: "new-id", source: "plaid", extra: { "plaid" => { "pending" => false } })
      mapping = copied_mapping
      expected = [ legacy, modern ].to_h { |entry| [ entry.id, { "entry" => entry.reload.attributes, "entryable" => entry.entryable.reload.attributes } ] }
      link_id = mapping.external_account.account_provider.id
      counts = [ Entry.count, Transaction.count, SourceRecord.count, EntrySource.count, IngestionBatch.count, Sync.count ]

      page = plan(mapping).page

      assert page.ready?
      assert page.complete
      assert_equal counts, [ Entry.count, Transaction.count, SourceRecord.count, EntrySource.count, IngestionBatch.count, Sync.count ]
      assert_equal link_id, page.document.fetch("account_provider_id")
      assert_equal "plaid", page.document.fetch("source")
      assert_equal mapping.source_checksum, page.document.fetch("archive_checksum")
      rows = page.document.fetch("rows").index_by { |row| row.fetch("entry_id") }
      assert_equal "legacy_plaid_id", rows.fetch(legacy.id).fetch("match_method")
      assert_equal "legacy_external_id", rows.fetch(modern.id).fetch("match_method")
      expected.each do |id, state|
        assert_equal state, Provider::AccountData::MigrationValue.decode(rows.fetch(id).fetch("financial_snapshot"))
        assert_equal state.fetch("entry"), Entry.find(id).attributes
      end
      assert_nil legacy.reload.external_id
      assert_nil legacy.source
      assert page.document.frozen?
      assert_raises(FrozenError) { page.document.fetch("rows").first["external_id"] = "changed" }
      refute_includes page.inspect, "old-id"
    end
  end

  test "explicit pending aliases preserve the booked UUID without making aliases current identities" do
    with_provider_encryption do
      entry = transaction(plaid_id: "pending-old", external_id: "booked", source: "plaid",
        extra: { "auto_claimed_pending_ids" => [ "pending-old" ], "plaid" => { "pending" => false, "pending_transaction_id" => "pending-new" } })
      mapping = copied_mapping(transactions: { "added" => [ raw_transaction("booked", pending_transaction_id: "pending-archive") ] })

      page = plan(mapping).page

      assert page.ready?
      row = page.document.fetch("rows").sole
      assert_equal entry.id, row.fetch("entry_id")
      assert_equal "booked", row.fetch("external_id")
      assert_equal %w[pending-archive pending-new pending-old], row.fetch("pending_aliases")
      assert_equal false, row.fetch("pending")
      assert_equal [ [ "raw_transactions_payload", "added", 0 ] ], row.fetch("archive_paths")
      assert_equal "pending-old", entry.reload.plaid_id
    end
  end

  test "unexplained divergent plaid_id is blocked rather than silently made an alias" do
    with_provider_encryption do
      entry = transaction(plaid_id: "other", external_id: "current", source: "plaid", extra: { "plaid" => { "pending" => false } })
      page = plan(copied_mapping).page
      assert_blocker page, entry, "divergent_legacy_identity"
      assert_equal "other", entry.reload.plaid_id
    end
  end

  test "an unapplied cached settlement preserves only the explicit current pending identity" do
    with_provider_encryption do
      entry = transaction(external_id: "pending", source: "plaid", extra: { "plaid" => { "pending" => true } },
        user_modified: true, import_locked: true, excluded: true, locked_attributes: { "name" => true })
      before = { "entry" => entry.attributes, "entryable" => entry.entryable.attributes }
      mapping = copied_mapping(transactions: { "added" => [ raw_transaction("booked", pending_transaction_id: "pending", amount: "999") ] })

      page = plan(mapping).page

      assert page.ready?
      row = page.document.fetch("rows").sole
      assert_equal entry.id, row.fetch("entry_id")
      assert_equal "pending", row.fetch("external_id")
      assert_equal "transaction", row.fetch("kind")
      assert row.fetch("pending")
      assert_empty row.fetch("pending_aliases")
      assert_empty row.fetch("archive_paths")
      assert_equal before, Provider::AccountData::MigrationValue.decode(row.fetch("financial_snapshot"))
      assert_equal before, { "entry" => entry.reload.attributes, "entryable" => entry.entryable.reload.attributes }
      assert_empty SourceRecord.where(external_account: mapping.external_account)
    end
  end

  test "cached settlement cannot invent a pending state or retire an alias on a current pending row" do
    with_provider_encryption do
      posted = transaction(external_id: "posted", source: "plaid", extra: { "plaid" => { "pending" => false } })
      unknown = transaction(external_id: "unknown", source: "plaid", extra: { "plaid" => {} })
      aliased = transaction(external_id: "aliased", source: "plaid",
        extra: { "plaid" => { "pending" => true }, "auto_claimed_pending_ids" => [ "older" ] })
      rows = [ posted, unknown, aliased ].map do |entry|
        raw_transaction("booked-#{entry.external_id}", pending_transaction_id: entry.external_id)
      end

      page = plan(copied_mapping(transactions: { "added" => rows })).page

      assert_empty page.document.fetch("rows")
      assert_equal [ posted.id, unknown.id, aliased.id ].sort, page.document.fetch("blockers").map { |blocker| blocker.fetch("entry_id") }.sort
      assert_equal [ "pending_transition_not_applied" ], page.document.fetch("blockers").map { |blocker| blocker.fetch("code") }.uniq
    end
  end

  test "pending-only bootstrap retains conflicting stream checks" do
    with_provider_encryption do
      pending = transaction(external_id: "pending", source: "plaid", extra: { "plaid" => { "pending" => true } })
      mapping = copied_mapping(transactions: { "added" => [ raw_transaction("booked", pending_transaction_id: "pending") ] },
        investments: { "transactions" => [ { "investment_transaction_id" => "pending", "type" => "cash" } ] })

      assert_blocker plan(mapping).page, pending, "conflicting_archive_identity"
    end
  end

  test "a cached settlement cannot claim a pending identity already owned by another Entry" do
    with_provider_encryption do
      pending = transaction(external_id: "pending", source: "plaid", extra: { "plaid" => { "pending" => true } })
      booked = transaction(external_id: "booked", source: "plaid",
        extra: { "plaid" => { "pending" => false, "pending_transaction_id" => "pending" } })

      page = plan(copied_mapping(transactions: { "added" => [ raw_transaction("booked", pending_transaction_id: "pending") ] })).page

      assert_empty page.document.fetch("rows")
      assert_equal [ pending.id, booked.id ].sort, page.document.fetch("blockers").map { |blocker| blocker.fetch("entry_id") }.sort
      assert_equal [ "identity_claimed_by_multiple_entries" ], page.document.fetch("blockers").map { |blocker| blocker.fetch("code") }.uniq
    end
  end

  test "investment cash transactions use activities while bank transactions use transactions" do
    with_provider_encryption do
      bank = transaction(external_id: "bank", source: "plaid")
      cash = transaction(external_id: "cash", source: "plaid")
      mapping = copied_mapping(transactions: { "modified" => [ raw_transaction("bank") ] },
        investments: { "transactions" => [ { "investment_transaction_id" => "cash", "account_id" => "acc_mock_1", "type" => "fee" } ] })
      page = plan(mapping).page

      assert page.ready?
      rows = page.document.fetch("rows").index_by { |row| row.fetch("entry_id") }
      assert_equal "transaction", rows.fetch(bank.id).fetch("kind")
      assert_equal "activity", rows.fetch(cash.id).fetch("kind")
      assert_equal "Transaction", rows.fetch(cash.id).fetch("entryable_type")
    end
  end

  test "missing archive history does not imply deletion or guess a cash transaction stream" do
    with_provider_encryption do
      entry = transaction(external_id: "not-in-latest-delta", source: "plaid")
      page = plan(copied_mapping).page
      assert_blocker page, entry, "unresolved_stream"
      assert entry.reload.persisted?
    end
  end

  test "removed archive IDs are identity evidence only and cannot delete an Entry" do
    with_provider_encryption do
      entry = transaction(plaid_id: "removed", user_modified: true)
      page = plan(copied_mapping(transactions: { "removed" => [ { "transaction_id" => "removed" } ] })).page
      assert page.ready?
      assert_equal "removed", page.document.fetch("rows").sole.fetch("external_id")
      assert entry.reload.user_modified?
    end
  end

  test "an identity present in both banking and investment archives is blocked" do
    with_provider_encryption do
      entry = transaction(external_id: "collision", source: "plaid")
      mapping = copied_mapping(transactions: { "added" => [ raw_transaction("collision") ] },
        investments: { "transactions" => [ { "investment_transaction_id" => "collision", "type" => "cash" } ] })
      assert_blocker plan(mapping).page, entry, "conflicting_archive_identity"
    end
  end

  test "cross-page legacy and pending alias collisions block both candidate UUIDs" do
    with_provider_encryption do
      first = transaction(id: "00000000-0000-4000-8000-000000000001", external_id: "first", source: "plaid",
        extra: { "plaid" => { "pending" => false }, "auto_claimed_pending_ids" => [ "shared" ] })
      transaction(id: "00000000-0000-4000-8000-000000000002", plaid_id: "shared", extra: { "plaid" => { "pending" => true } })
      page = plan(copied_mapping).page(limit: 1)
      assert_blocker page, first, "identity_claimed_by_multiple_entries"
      assert_nil page.next_cursor
      assert_not page.complete
    end
  end

  test "bounded continuation is bound to exact account mapping archive and writer epoch" do
    with_provider_encryption do
      3.times do |index|
        transaction(external_id: "row-#{index}", source: "plaid", extra: { "plaid" => { "pending" => false } })
      end
      mapping = copied_mapping
      planner = plan(mapping)
      first = planner.page(limit: 1)
      second = planner.page(cursor: first.next_cursor, limit: 1)
      third = planner.page(cursor: second.next_cursor, limit: 1)

      assert_not first.complete
      assert third.complete
      assert_nil third.next_cursor
      assert_equal 3, [ first, second, third ].flat_map { |page| page.document.fetch("rows").map { |row| row.fetch("entry_id") } }.uniq.size
      assert_raises(Plan::InvalidContext) { planner.page(cursor: first.next_cursor.merge("account_provider_id" => SecureRandom.uuid)) }
      mapping.provider_migration_control.increment!(:writer_epoch)
      assert_raises(Plan::InvalidContext) { planner.page(cursor: first.next_cursor) }
    end
  end

  test "EU uses the same plaid financial source and keeps the original account-provider UUID" do
    with_provider_encryption do
      plaid_items(:one).update!(plaid_region: "eu")
      entry = transaction(external_id: "eu-txn", source: "plaid", extra: { "plaid" => { "pending" => false } })
      link = AccountProvider.create!(account: accounts(:connected), provider: plaid_accounts(:one))
      mapping = copied_mapping
      page = plan(mapping).page
      assert page.ready?
      assert_equal "eu", mapping.external_account.provider_connection.region
      assert_equal "plaid", page.document.fetch("source")
      assert_equal link.id, page.document.fetch("account_provider_id")
      assert_equal entry.id, page.document.fetch("rows").sole.fetch("entry_id")
    end
  end

  test "final inventory includes blocked rows and a fresh sweep finds insertions behind the cursor" do
    with_provider_encryption do
      blocked = transaction(id: "00000000-0000-4000-8000-000000000002", external_id: "unclassified", source: "plaid")
      accepted = transaction(id: "00000000-0000-4000-8000-000000000003", external_id: "accepted", source: "plaid",
        extra: { "plaid" => { "pending" => false } })
      mapping = copied_mapping
      planner = plan(mapping)
      page = planner.page(limit: 1)
      assert_blocker page, blocked, "unresolved_stream"
      assert_nil page.next_cursor
      assert_equal [ blocked.id ], planner.candidate_entry_ids(limit: 1)
      assert_equal [ accepted.id ], planner.candidate_entry_ids(after_id: blocked.id, limit: 1)

      late = transaction(id: "00000000-0000-4000-8000-000000000001", plaid_id: "late",
        extra: { "plaid" => { "pending" => false } })
      transaction # A manual record without a Plaid identity is outside the inventory.
      assert_empty planner.candidate_entry_ids(after_id: accepted.id)
      assert_equal [ late.id, blocked.id, accepted.id ], planner.candidate_entry_ids
      assert_raises(Plan::InvalidContext) { planner.candidate_entry_ids(after_id: "invalid") }
      assert_raises(ArgumentError) { planner.candidate_entry_ids(limit: 501) }
      assert_raises(Plan::InvalidContext) { Plan.new(mapping: mapping, family: families(:empty)).candidate_entry_ids }
    end
  end

  test "foreign source and unscoped external identities are never claimed through plaid_id" do
    with_provider_encryption do
      foreign = transaction(plaid_id: "legacy", source: "up", external_id: "up-1")
      unscoped = transaction(plaid_id: "legacy-2", external_id: "unscoped")
      page = plan(copied_mapping).page
      assert_equal({ foreign.id => "conflicting_source", unscoped.id => "unscoped_external_id" },
        page.document.fetch("blockers").to_h { |blocker| [ blocker.fetch("entry_id"), blocker.fetch("code") ] })
      assert_empty page.document.fetch("rows")
    end
  end

  test "foreign family unverified copy or active connection cannot produce a plan" do
    with_provider_encryption do
      mapping = copied_mapping
      assert_raises(Plan::InvalidContext) { Plan.new(mapping: mapping, family: families(:empty)).page }
      mapping.update!(verified_at: nil)
      assert_raises(Plan::InvalidContext) { plan(mapping).page }
      mapping.update!(verified_at: Time.current)
      mapping.external_account.provider_connection.update!(status: "good")
      assert_raises(Plan::InvalidContext) { plan(mapping).page }
    end
  end

  test "an archived record declaring a foreign provider account aborts identity planning" do
    with_provider_encryption do
      mapping = copied_mapping(transactions: { "added" => [ raw_transaction("foreign").merge("account_id" => "another-account") ] })
      assert_raises(Plan::InvalidContext) { plan(mapping).page }
    end
  end

  test "an existing native mapping to another financial UUID cannot be overwritten by a legacy plan" do
    with_provider_encryption do
      legacy = transaction(plaid_id: "legacy", extra: { "plaid" => { "pending" => false } })
      other = transaction
      mapping = copied_mapping
      external = mapping.external_account
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions")
      source = SourceRecord.create!(family: families(:dylan_family), account: accounts(:connected), external_account: external,
        ingestion_batch: batch, kind: "transaction", external_id: "legacy")
      source.create_entry_source!(entry: other, account: accounts(:connected), family: families(:dylan_family), role: "posting", match_method: "provider_reconciliation")

      assert_blocker plan(mapping).page, legacy, "conflicting_native_evidence"
      assert_equal other.id, source.reload.entry_source.entry_id
    end
  end

  private
    def transaction(extra: nil, **attributes)
      accounts(:connected).entries.create!({ entryable: Transaction.new(extra: extra), name: "Original protected description",
        date: Date.current, amount: BigDecimal("123.4567"), currency: "USD" }.merge(attributes))
    end

    def raw_transaction(id, **attributes)
      { "transaction_id" => id, "account_id" => "acc_mock_1", "pending" => false }.merge(attributes.stringify_keys)
    end

    def copied_mapping(transactions: {}, investments: {})
      plaid_accounts(:one).update!(raw_transactions_payload: transactions, raw_holdings_payload: investments)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "plaid", legacy_item_id: plaid_items(:one).id)
      10.times do
        copier.run
        break if copier.control.reload.shadow?
      end
      assert copier.control.shadow?
      copier.control.provider_migration_mappings.find_by!(legacy_id: plaid_accounts(:one).id, role: "external_account")
    end

    def plan(mapping)
      Plan.new(mapping: mapping, family: families(:dylan_family))
    end

    def assert_blocker(page, entry, code)
      assert_not page.ready?
      assert_equal [ { "entry_id" => entry.id, "code" => code } ], page.document.fetch("blockers")
      assert_empty page.document.fetch("rows")
    end
end
