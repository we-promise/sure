require "test_helper"

class SimplefinItem::ImporterOrphanPruneTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @sync = Sync.create!(syncable: @item)
  end

  test "prunes orphaned SimplefinAccount records when upstream account_ids change" do
    # Create an existing SimplefinAccount with an OLD account_id (simulating a previously synced account)
    old_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-old-id-12345",
      name: "Business",
      currency: "USD",
      current_balance: 100,
      account_type: "checking"
    )

    # Stub provider to return accounts with NEW account_ids (simulating re-added institution)
    mock_provider = mock()
    mock_provider.expects(:get_accounts).at_least_once.returns({
      accounts: [
        { id: "ACT-new-id-67890", name: "Business", balance: "288.41", currency: "USD", type: "checking" }
      ]
    })

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock_provider, sync: @sync)
    importer.send(:perform_account_discovery)

    # The old SimplefinAccount should be pruned
    assert_nil SimplefinAccount.find_by(id: old_sfa.id), "old SimplefinAccount with stale account_id should be deleted"

    # A new SimplefinAccount should exist with the new account_id
    new_sfa = @item.simplefin_accounts.find_by(account_id: "ACT-new-id-67890")
    assert_not_nil new_sfa, "new SimplefinAccount should be created"
    assert_equal "Business", new_sfa.name

    # Stats should reflect the pruning
    stats = @sync.reload.sync_stats
    assert_equal 1, stats["accounts_pruned"], "should track pruned accounts"
  end

  test "does not prune SimplefinAccount that is linked to an Account via legacy FK" do
    # Create a SimplefinAccount with an old account_id
    old_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-old-id-12345",
      name: "Business",
      currency: "USD",
      current_balance: 100,
      account_type: "checking"
    )

    # Link it to an Account via legacy FK
    account = Account.create!(
      family: @family,
      name: "Business Checking",
      currency: "USD",
      balance: 100,
      accountable: Depository.create!(subtype: :checking),
      simplefin_account_id: old_sfa.id
    )

    # Stub provider to return accounts with NEW account_ids
    mock_provider = mock()
    mock_provider.expects(:get_accounts).at_least_once.returns({
      accounts: [
        { id: "ACT-new-id-67890", name: "Business", balance: "288.41", currency: "USD", type: "checking" }
      ]
    })

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock_provider, sync: @sync)
    importer.send(:perform_account_discovery)

    # The old SimplefinAccount should NOT be pruned because it's linked
    assert_not_nil SimplefinAccount.find_by(id: old_sfa.id), "linked SimplefinAccount should not be deleted"

    # New SimplefinAccount should also exist
    new_sfa = @item.simplefin_accounts.find_by(account_id: "ACT-new-id-67890")
    assert_not_nil new_sfa, "new SimplefinAccount should be created"

    # Stats should not show any pruning
    stats = @sync.reload.sync_stats
    assert_nil stats["accounts_pruned"], "should not prune linked accounts"
  end

  test "does not prune SimplefinAccount that is linked via AccountProvider" do
    # Create a SimplefinAccount with an old account_id
    old_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-old-id-12345",
      name: "Business",
      currency: "USD",
      current_balance: 100,
      account_type: "checking"
    )

    # Create an Account and link via AccountProvider (new system)
    account = Account.create!(
      family: @family,
      name: "Business Checking",
      currency: "USD",
      balance: 100,
      accountable: Depository.create!(subtype: :checking)
    )
    AccountProvider.create!(account: account, provider: old_sfa)

    # Stub provider to return accounts with NEW account_ids
    mock_provider = mock()
    mock_provider.expects(:get_accounts).at_least_once.returns({
      accounts: [
        { id: "ACT-new-id-67890", name: "Business", balance: "288.41", currency: "USD", type: "checking" }
      ]
    })

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock_provider, sync: @sync)
    importer.send(:perform_account_discovery)

    # The old SimplefinAccount should NOT be pruned because it's linked via AccountProvider
    assert_not_nil SimplefinAccount.find_by(id: old_sfa.id), "linked SimplefinAccount should not be deleted"

    # Stats should not show any pruning
    stats = @sync.reload.sync_stats
    assert_nil stats["accounts_pruned"], "should not prune linked accounts"
  end

  test "prunes multiple orphaned SimplefinAccounts when institution re-added with all new IDs" do
    # Create two old SimplefinAccounts (simulating two accounts from before re-add)
    old_sfa1 = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-old-business",
      name: "Business",
      currency: "USD",
      current_balance: 28.41,
      account_type: "checking"
    )

    old_sfa2 = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-old-personal",
      name: "Personal",
      currency: "USD",
      current_balance: 308.43,
      account_type: "checking"
    )

    # Stub provider to return accounts with entirely NEW account_ids
    mock_provider = mock()
    mock_provider.expects(:get_accounts).at_least_once.returns({
      accounts: [
        { id: "ACT-new-business", name: "Business", balance: "288.41", currency: "USD", type: "checking" },
        { id: "ACT-new-personal", name: "Personal", balance: "22.43", currency: "USD", type: "checking" }
      ]
    })

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock_provider, sync: @sync)
    importer.send(:perform_account_discovery)

    # Both old SimplefinAccounts should be pruned
    assert_nil SimplefinAccount.find_by(id: old_sfa1.id), "old Business SimplefinAccount should be deleted"
    assert_nil SimplefinAccount.find_by(id: old_sfa2.id), "old Personal SimplefinAccount should be deleted"

    # New SimplefinAccounts should exist
    assert_equal 2, @item.simplefin_accounts.reload.count, "should have exactly 2 SimplefinAccounts"
    assert_not_nil @item.simplefin_accounts.find_by(account_id: "ACT-new-business")
    assert_not_nil @item.simplefin_accounts.find_by(account_id: "ACT-new-personal")

    # Stats should reflect both pruned
    stats = @sync.reload.sync_stats
    assert_equal 2, stats["accounts_pruned"], "should track both pruned accounts"
  end
end
