require "test_helper"

class Trading212ItemBroadcastRenderTest < ActiveSupport::TestCase
  # Trading212Item::SyncCompleteEvent#broadcast re-renders this partial from the
  # sync job, outside any request, so Current.user is nil there.
  test "the connection card renders its accounts with no current user" do
    item = trading212_items(:configured_item)
    account = accounts(:investment)
    AccountProvider.create!(account: account, provider: trading212_accounts(:main_account))

    Current.reset
    assert_nil Current.user

    html = ApplicationController.render(
      partial: "trading212_items/trading212_item",
      locals: { trading212_item: item.reload }
    )

    assert_includes html, ERB::Util.html_escape(account.name)
  end
end
