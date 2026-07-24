require "test_helper"

class SimplefinItemTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Connection",
      access_url: "https://example.com/access_token"
    )
  end

  test "stale_pending_status excludes split parents and children" do
    account = Account.create!(
      family: @family, name: "SF Checking",
      accountable: Depository.new(subtype: "checking"), balance: 0, currency: "USD"
    )
    sf_account = @simplefin_item.simplefin_accounts.create!(
      name: "SF", account_id: "sf_stale", currency: "USD",
      account_type: "checking", current_balance: 0
    )
    account.update!(simplefin_account_id: sf_account.id)

    # Standalone stale (>8 days) pending entry — should be counted.
    standalone = create_transaction(
      account: account, amount: 20, currency: "USD", date: 10.days.ago.to_date, source: "simplefin"
    )
    standalone.transaction.update!(extra: { "simplefin" => { "pending" => true } })

    # Split stale pending family: parent is excluded; children inherit the pending flag.
    # Neither should be counted — auto_exclude_stale_pending skips them, so counting them
    # would show a warning that can never reach zero.
    parent = create_transaction(
      account: account, amount: 100, currency: "USD", date: 10.days.ago.to_date, source: "simplefin"
    )
    parent.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    parent.split!([
      { name: "Part A", amount: 60, category_id: nil },
      { name: "Part B", amount: 40, category_id: nil }
    ])

    status = @simplefin_item.stale_pending_status(days: 8)

    assert_equal 1, status[:count],
      "only the standalone stale pending entry should be counted, not the split parent or its children"
  end

  test "belongs to family" do
    assert_equal @family, @simplefin_item.family
  end

  test "has many simplefin_accounts" do
    account = @simplefin_item.simplefin_accounts.create!(
      name: "Test Account",
      account_id: "test_123",
      currency: "USD",
      account_type: "checking",
      current_balance: 1000.00
    )

    assert_includes @simplefin_item.simplefin_accounts, account
  end

  test "has good status by default" do
    assert_equal "good", @simplefin_item.status
  end

  test "setup token update is required when requires_update has no successful account sync" do
    @simplefin_item.update!(status: :requires_update)
    Sync.create!(
      syncable: @simplefin_item,
      status: "failed",
      failed_at: Time.current,
      error: "SimpleFIN access forbidden",
      sync_stats: { "total_accounts" => 0 }
    )

    assert @simplefin_item.setup_token_update_required?
    assert_equal "requires_update", @simplefin_item.effective_status
    assert_includes @simplefin_item.attention_summary, "Connection needs update"
  end

  test "setup token update is not required when latest sync returned accounts" do
    @simplefin_item.update!(status: :requires_update, pending_account_setup: true)
    # Must be a terminal sync: a pending/in-progress sync short-circuits before
    # the account-count check, so this would pass without exercising the branch.
    Sync.create!(
      syncable: @simplefin_item,
      status: "completed",
      completed_at: Time.current,
      sync_stats: {
        "total_accounts" => 18,
        "error_buckets" => { "auth" => 1 },
        "errors" => [ "Connection to Cash App may need attention. Auth required" ]
      }
    )

    refute @simplefin_item.setup_token_update_required?
    assert_equal "good", @simplefin_item.effective_status
    refute_includes @simplefin_item.attention_summary, "Connection needs update"
    assert_includes @simplefin_item.attention_summary, "Accounts need setup"
  end

  test "setup token update is not required when latest sync stats use symbol keys" do
    @simplefin_item.update!(status: :requires_update)
    latest_sync = Sync.new(
      syncable: @simplefin_item,
      status: "completed",
      completed_at: Time.current,
      sync_stats: {
        total_accounts: 18,
        error_buckets: { auth: 1 }
      }
    )

    refute @simplefin_item.setup_token_update_required?(latest_sync:)
    assert_equal "good", @simplefin_item.effective_status(latest_sync:)
  end

  test "setup token update is not required while latest sync is unresolved" do
    @simplefin_item.update!(status: :requires_update)
    Sync.create!(
      syncable: @simplefin_item,
      status: "pending",
      sync_stats: {
        "import_started" => true
      }
    )

    refute @simplefin_item.setup_token_update_required?
    assert_equal "good", @simplefin_item.effective_status
  end

  test "setup token update is required when latest sync is stale without accounts" do
    @simplefin_item.update!(status: :requires_update)
    Sync.create!(
      syncable: @simplefin_item,
      status: "stale",
      sync_stats: {
        "import_started" => true
      }
    )

    assert @simplefin_item.setup_token_update_required?
    assert_equal "requires_update", @simplefin_item.effective_status
  end

  test "can be marked for deletion" do
    refute @simplefin_item.scheduled_for_deletion?

    @simplefin_item.destroy_later

    assert @simplefin_item.scheduled_for_deletion?
  end

  test "is syncable" do
    assert_respond_to @simplefin_item, :sync_later
    assert_respond_to @simplefin_item, :syncing?
  end

  test "scopes work correctly" do
    # Create one for deletion
    item_for_deletion = SimplefinItem.create!(
      family: @family,
      name: "Delete Me",
      access_url: "https://example.com/delete_token",
      scheduled_for_deletion: true
    )

    active_items = SimplefinItem.active
    ordered_items = SimplefinItem.ordered

    assert_includes active_items, @simplefin_item
    refute_includes active_items, item_for_deletion

    assert_equal [ @simplefin_item, item_for_deletion ].sort_by(&:created_at).reverse,
                 ordered_items.to_a
  end

  test "upserts institution data correctly" do
    org_data = {
      id: "bank123",
      name: "Test Bank",
      domain: "testbank.com",
      url: "https://testbank.com",
      "sfin-url": "https://sfin.testbank.com"
    }

    @simplefin_item.upsert_institution_data!(org_data)

    assert_equal "bank123", @simplefin_item.institution_id
    assert_equal "Test Bank", @simplefin_item.institution_name
    assert_equal "testbank.com", @simplefin_item.institution_domain
    assert_equal "https://testbank.com", @simplefin_item.institution_url
    assert_equal org_data.stringify_keys, @simplefin_item.raw_institution_payload
  end

  test "institution display name fallback works" do
    # No institution data
    assert_equal @simplefin_item.name, @simplefin_item.institution_display_name

    # With institution name
    @simplefin_item.update!(institution_name: "Chase Bank")
    assert_equal "Chase Bank", @simplefin_item.institution_display_name

    # With domain fallback
    @simplefin_item.update!(institution_name: nil, institution_domain: "chase.com")
    assert_equal "chase.com", @simplefin_item.institution_display_name
  end

  test "connected institutions returns unique institutions" do
    # Create accounts with different institutions
    account1 = @simplefin_item.simplefin_accounts.create!(
      name: "Checking",
      account_id: "acc1",
      currency: "USD",
      account_type: "checking",
      current_balance: 1000,
      org_data: { "name" => "Chase Bank", "domain" => "chase.com" }
    )

    account2 = @simplefin_item.simplefin_accounts.create!(
      name: "Savings",
      account_id: "acc2",
      currency: "USD",
      account_type: "savings",
      current_balance: 2000,
      org_data: { "name" => "Wells Fargo", "domain" => "wellsfargo.com" }
    )

    institutions = @simplefin_item.connected_institutions
    assert_equal 2, institutions.count
    assert_includes institutions.map { |i| i["name"] }, "Chase Bank"
    assert_includes institutions.map { |i| i["name"] }, "Wells Fargo"
  end

  test "institution summary with multiple institutions" do
    # No institutions
    assert_equal "No institutions connected", @simplefin_item.institution_summary

    # One institution
    @simplefin_item.simplefin_accounts.create!(
      name: "Checking",
      account_id: "acc1",
      currency: "USD",
      account_type: "checking",
      current_balance: 1000,
      org_data: { "name" => "Chase Bank" }
    )
    assert_equal "Chase Bank", @simplefin_item.institution_summary

    # Multiple institutions
    @simplefin_item.simplefin_accounts.create!(
      name: "Savings",
      account_id: "acc2",
      currency: "USD",
      account_type: "savings",
      current_balance: 2000,
      org_data: { "name" => "Wells Fargo" }
    )
    assert_equal "2 institutions", @simplefin_item.institution_summary
  end
end
