require "test_helper"

class PlaidItemBroadcastRenderTest < ActiveSupport::TestCase
  # PlaidItem::SyncCompleteEvent#broadcast re-renders this partial from the
  # sync job, outside any request, so Current.user is nil there. A
  # viewer-dependent filter in the partial would silently empty the account
  # list for every family member on every completed sync.
  test "the connection card still renders its accounts with no current user" do
    item = plaid_items(:one)
    account = item.accounts.first
    assert account.present?, "fixture item needs at least one account"

    Current.reset
    assert_nil Current.user

    html = ApplicationController.render(
      partial: "plaid_items/plaid_item",
      locals: { plaid_item: item }
    )

    assert_includes html, account.name
  end
end
