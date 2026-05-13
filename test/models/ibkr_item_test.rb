require "test_helper"

class IbkrItemTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items

  test "syncable excludes items without token" do
    item = IbkrItem.create!(
      family: families(:empty),
      name: "Interactive Brokers",
      query_id: "QUERYNEW",
      token: "TOKENNEW"
    )

    item.token = nil
    item.save!(validate: false)

    assert_includes IbkrItem.syncable, ibkr_items(:configured_item)
    refute_includes IbkrItem.syncable, item
  end
end
