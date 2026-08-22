require "test_helper"

class UpAccountTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @up_item = UpItem.create!(family: @family, name: "Test Up", access_token: "up-access-token")
  end

  test "prune_stale_pending_entries never destroys split parents or their children" do
    account = Account.create!(
      family: @family, name: "Up Checking",
      accountable: Depository.new(subtype: "checking"), balance: 0, currency: "AUD"
    )
    up_account = UpAccount.create!(up_item: @up_item, name: "Up", account_id: "acc_prune", currency: "AUD")
    AccountProvider.create!(account: account, provider: up_account)

    # Standalone pending up entry whose hold has dropped — should be pruned.
    standalone = create_transaction(
      account: account, amount: 20, currency: "AUD",
      external_id: "up_standalone_pending", source: "up"
    )
    standalone.transaction.update!(extra: { "up" => { "pending" => true } })

    # Split pending up family: parent keeps its pending flag + source and is excluded.
    parent = create_transaction(
      account: account, amount: 100, currency: "AUD",
      external_id: "up_split_pending", source: "up"
    )
    parent.transaction.update!(extra: { "up" => { "pending" => true } })
    parent.split!([
      { name: "Part A", amount: 60, category_id: nil },
      { name: "Part B", amount: 40, category_id: nil }
    ])
    child_ids = parent.reload.child_entries.pluck(:id)

    processor = UpAccount::Transactions::Processor.new(up_account)
    pruned = processor.send(:prune_stale_pending_entries, [])

    assert_equal 1, pruned, "only the standalone pending entry should be pruned"
    refute Entry.exists?(standalone.id), "standalone stale pending entry should be pruned"
    assert Entry.exists?(parent.id), "split parent must never be pruned (would cascade-delete children)"
    child_ids.each do |id|
      assert Entry.exists?(id), "split child must survive the prune"
    end
  end

  test "needs_setup excludes linked and ignored accounts" do
    unlinked = UpAccount.create!(up_item: @up_item, name: "Unlinked", account_id: "acc_unlinked", currency: "AUD")
    ignored  = UpAccount.create!(up_item: @up_item, name: "Skipped", account_id: "acc_ignored", currency: "AUD", ignored: true)

    linked = UpAccount.create!(up_item: @up_item, name: "Linked", account_id: "acc_linked", currency: "AUD")
    account = Account.create!(family: @family, name: "Linked", accountable: Depository.new(subtype: "checking"), balance: 0, currency: "AUD")
    AccountProvider.create!(account: account, provider: linked)

    needs_setup = @up_item.up_accounts.needs_setup

    assert_includes needs_setup, unlinked
    assert_not_includes needs_setup, ignored
    assert_not_includes needs_setup, linked
    assert_equal 1, @up_item.unlinked_accounts_count
  end
end
