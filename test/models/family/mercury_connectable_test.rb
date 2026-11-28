require "test_helper"

class Family::MercuryConnectableTest < ActiveSupport::TestCase
  test "a connection created with a blank name gets the default name" do
    MercuryItem.any_instance.stubs(:sync_later)

    item = families(:dylan_family).create_mercury_item!(token: "new_token", item_name: "")

    assert_equal I18n.t("mercury_items.default_connection_name"), item.name
  end
end
