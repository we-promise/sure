require "test_helper"

class Family::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "syncs plaid items and manual accounts" do
    family_sync = syncs(:family)

    manual_accounts_count = @family.accounts.manual.count
    items_count = @family.plaid_items.count

    syncer = Family::Syncer.new(@family)

    Account.any_instance
           .expects(:sync_later)
           .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
           .times(manual_accounts_count)

    PlaidItem.any_instance
             .expects(:sync_later)
             .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
             .times(items_count)

    syncer.perform_sync(family_sync)

    assert_equal "completed", family_sync.reload.status
  end

  test "only applies active rules during sync" do
    family_sync = syncs(:family)

    # Create an active rule
    active_rule = @family.rules.create!(
      resource_type: "transaction",
      active: true,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    # Create a disabled rule
    disabled_rule = @family.rules.create!(
      resource_type: "transaction",
      active: false,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    syncer = Family::Syncer.new(@family)

    # Stub the relation to return our specific instances so expectations work
    @family.rules.stubs(:where).with(active: true).returns([ active_rule ])

    # Expect apply_later to be called only for the active rule
    active_rule.expects(:apply_later).once
    disabled_rule.expects(:apply_later).never

    # Mock the account and plaid item syncs to avoid side effects
    Account.any_instance.stubs(:sync_later)
    PlaidItem.any_instance.stubs(:sync_later)
    SimplefinItem.any_instance.stubs(:sync_later)
    LunchflowItem.any_instance.stubs(:sync_later)
    EnableBankingItem.any_instance.stubs(:sync_later)

    syncer.perform_sync(family_sync)
    syncer.perform_post_sync
  end
end
