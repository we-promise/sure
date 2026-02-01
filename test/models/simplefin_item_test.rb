require "test_helper"

class SimplefinItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Connection",
      access_url: "https://example.com/access_token"
    )
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

  test "process_accounts skips disabled accounts" do
    # Create a SimpleFin account with linked Account
    simplefin_account = @simplefin_item.simplefin_accounts.create!(
      name: "Test Checking",
      account_id: "test_checking_123",
      currency: "USD",
      account_type: "checking",
      current_balance: 5000
    )

    # Create a linked Account via AccountProvider
    account = @family.accounts.create!(
      name: "Test Checking Account",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )

    # Link via AccountProvider
    AccountProvider.create!(
      account: account,
      provider: simplefin_account
    )

    # Verify the account is visible and linked
    assert account.visible?
    assert_equal account, simplefin_account.current_account

    # Mock the processor to track if it was called
    processor_called = false
    SimplefinAccount::Processor.any_instance.stubs(:process).with do
      processor_called = true
    end

    # Process accounts - should call processor for active account
    @simplefin_item.process_accounts
    assert processor_called, "Processor should be called for visible account"

    # Reset flag
    processor_called = false

    # Disable the account
    account.disable!
    refute account.visible?

    # Process accounts again - should NOT call processor for disabled account
    @simplefin_item.process_accounts
    refute processor_called, "Processor should NOT be called for disabled account"
  end

  test "schedule_account_syncs skips disabled accounts" do
    # Create a SimpleFin account with linked Account
    simplefin_account = @simplefin_item.simplefin_accounts.create!(
      name: "Test Savings",
      account_id: "test_savings_123",
      currency: "USD",
      account_type: "savings",
      current_balance: 10000
    )

    # Create a linked Account via AccountProvider
    account = @family.accounts.create!(
      name: "Test Savings Account",
      balance: 2000,
      currency: "USD",
      accountable: Depository.new
    )

    # Link via AccountProvider
    AccountProvider.create!(
      account: account,
      provider: simplefin_account
    )

    # Verify the account is visible
    assert account.visible?

    # Mock sync_later to track if it was called
    sync_later_called = false
    Account.any_instance.stubs(:sync_later).with do
      sync_later_called = true
    end

    # Schedule syncs - should call sync_later for active account
    @simplefin_item.schedule_account_syncs
    assert sync_later_called, "sync_later should be called for visible account"

    # Reset flag
    sync_later_called = false

    # Disable the account
    account.disable!
    refute account.visible?

    # Schedule syncs again - should NOT call sync_later for disabled account
    @simplefin_item.schedule_account_syncs
    refute sync_later_called, "sync_later should NOT be called for disabled account"
  end
end
