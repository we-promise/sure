require "test_helper"

class Trading212ItemBroadcastRenderTest < ActiveSupport::TestCase
  # #3630. The card takes its accounts only from visible_accounts, never from
  # Current.user. It used to filter with Current.user.accessible_accounts
  # directly, so any render without a viewer raised.
  test "the connection card renders with no current user" do
    Current.reset
    assert_nil Current.user

    assert_nothing_raised do
      ApplicationController.render(
        partial: "trading212_items/trading212_item",
        locals: { trading212_item: trading212_items(:configured_item), visible_accounts: trading212_items(:configured_item).accounts }
      )
    end
  end
end
