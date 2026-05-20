require "test_helper"

class LunchflowItem::ImporterOrphanPruneTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = LunchflowItem.create!(
      family: @family,
      name: "Test Lunchflow",
      api_key: "test_key_123",
      status: :good
    )
    @importer = LunchflowItem::Importer.new(@item, lunchflow_provider: mock())
  end

  test "prunes orphaned unlinked LunchflowAccount no longer returned upstream" do
    orphan = @item.lunchflow_accounts.create!(
      account_id: "acct-old",
      name: "Deleted Account",
      currency: "USD"
    )

    pruned = @importer.send(:prune_orphaned_lunchflow_accounts, [ "acct-new" ])

    assert_equal 1, pruned
    assert_nil LunchflowAccount.find_by(id: orphan.id), "orphaned unlinked account should be deleted"
  end

  test "keeps unlinked LunchflowAccount that is still returned upstream" do
    still_present = @item.lunchflow_accounts.create!(
      account_id: "acct-keep",
      name: "Active Account",
      currency: "USD"
    )

    pruned = @importer.send(:prune_orphaned_lunchflow_accounts, [ "acct-keep" ])

    assert_equal 0, pruned
    assert_not_nil LunchflowAccount.find_by(id: still_present.id)
  end

  test "does not prune a LunchflowAccount linked via AccountProvider" do
    linked = @item.lunchflow_accounts.create!(
      account_id: "acct-linked",
      name: "Linked Account",
      currency: "USD"
    )
    account = @family.accounts.create!(
      name: "Linked Checking",
      balance: 100,
      currency: "USD",
      accountable: Depository.new(subtype: "checking")
    )
    AccountProvider.create!(account: account, provider: linked)

    # Even though it's gone upstream, a linked account must be kept (deleting it
    # would cascade-destroy the AccountProvider and orphan the user's Account).
    pruned = @importer.send(:prune_orphaned_lunchflow_accounts, [ "acct-other" ])

    assert_equal 0, pruned
    assert_not_nil LunchflowAccount.find_by(id: linked.id), "linked account should not be deleted"
  end

  test "blank upstream list is a no-op so transient failures cannot wipe accounts" do
    orphan = @item.lunchflow_accounts.create!(
      account_id: "acct-old",
      name: "Account",
      currency: "USD"
    )

    assert_equal 0, @importer.send(:prune_orphaned_lunchflow_accounts, [])
    assert_not_nil LunchflowAccount.find_by(id: orphan.id), "must not prune when upstream list is empty"
  end

  test "prunes multiple orphaned unlinked accounts" do
    orphan1 = @item.lunchflow_accounts.create!(account_id: "old-1", name: "One", currency: "USD")
    orphan2 = @item.lunchflow_accounts.create!(account_id: "old-2", name: "Two", currency: "USD")
    kept = @item.lunchflow_accounts.create!(account_id: "new-1", name: "Three", currency: "USD")

    pruned = @importer.send(:prune_orphaned_lunchflow_accounts, [ "new-1" ])

    assert_equal 2, pruned
    assert_nil LunchflowAccount.find_by(id: orphan1.id)
    assert_nil LunchflowAccount.find_by(id: orphan2.id)
    assert_not_nil LunchflowAccount.find_by(id: kept.id)
  end
end
