require "test_helper"

# Mercury's connection actions behave as the provider kit's do.
class MercuryItemsConnectionTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @item = mercury_items(:one)
  end

  test "a connection created with a blank name gets the default name" do
    assert_difference "MercuryItem.count", 1 do
      post mercury_items_url, params: { mercury_item: { name: "", token: "new_token" } }
    end

    assert_equal "Mercury Connection", MercuryItem.order(:created_at).last.name
  end

  test "a connection created without a name gets the default name" do
    post mercury_items_url, params: { mercury_item: { token: "new_token" } }

    assert_equal "Mercury Connection", MercuryItem.order(:created_at).last.name
  end

  test "a sync started from the panel re-renders the panel" do
    post sync_mercury_item_url(@item), params: { source: "panel" }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, "mercury-providers-panel"
  end

  test "a sync started from the card still redirects back" do
    post sync_mercury_item_url(@item)

    assert_redirected_to accounts_path
  end

  test "an unlink failure escaping unlink_all! is no longer swallowed by destroy" do
    MercuryItem.any_instance.stubs(:unlink_all!).raises(ActiveRecord::StatementInvalid, "database unavailable")

    assert_raises(ActiveRecord::StatementInvalid) { delete mercury_item_url(@item) }

    assert_not @item.reload.scheduled_for_deletion?
  end
end
