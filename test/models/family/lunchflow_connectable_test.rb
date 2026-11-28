require "test_helper"

class Family::LunchflowConnectableTest < ActiveSupport::TestCase
  test "a connection created with a blank name gets the default name" do
    LunchflowItem.any_instance.stubs(:sync_later)

    item = families(:dylan_family).create_lunchflow_item!(api_key: "new_key", item_name: "")

    assert_equal I18n.t("lunchflow_items.default_connection_name"), item.name
  end
end
