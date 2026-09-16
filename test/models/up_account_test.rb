require "test_helper"

class UpAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @up_item = UpItem.create!(family: @family, name: "Test Up", access_token: "up-access-token")
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
