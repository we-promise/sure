require "test_helper"

class Trading212ItemBroadcastRenderTest < ActiveSupport::TestCase
  # #3630. The card is rendered outside a request as well, where Current.user
  # is nil. Its account filter read Current.user.accessible_accounts directly,
  # so any render without a viewer raised.
  test "the connection card renders with no current user" do
    Current.reset
    assert_nil Current.user

    assert_nothing_raised do
      ApplicationController.render(
        partial: "trading212_items/trading212_item",
        locals: { trading212_item: trading212_items(:configured_item) }
      )
    end
  end
end
