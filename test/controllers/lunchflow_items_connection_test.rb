require "test_helper"

# Lunch Flow's connection actions behave as the provider kit's do.
class LunchflowItemsConnectionTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @item = lunchflow_items(:one)
  end

  test "a connection created with a blank name gets the default name" do
    assert_difference "LunchflowItem.count", 1 do
      post lunchflow_items_url, params: { lunchflow_item: { name: "", api_key: "new_key" } }
    end

    assert_equal "Lunch Flow Connection", LunchflowItem.order(:created_at).last.name
  end

  test "a connection created without a name gets the default name" do
    post lunchflow_items_url, params: { lunchflow_item: { api_key: "new_key" } }

    assert_equal "Lunch Flow Connection", LunchflowItem.order(:created_at).last.name
  end

  test "a sync started from the panel re-renders the panel" do
    LunchflowItem.any_instance.expects(:sync_later).once

    post sync_lunchflow_item_url(@item), params: { source: "panel" }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, "lunchflow-providers-panel"
  end

  test "a sync started from the card still redirects back" do
    post sync_lunchflow_item_url(@item)

    assert_redirected_to accounts_path
  end

  test "an unlink failure escaping unlink_all! is no longer swallowed by destroy" do
    LunchflowItem.any_instance.stubs(:unlink_all!).raises(ActiveRecord::StatementInvalid, "database unavailable")

    assert_raises(ActiveRecord::StatementInvalid) { delete lunchflow_item_url(@item) }

    assert_not @item.reload.scheduled_for_deletion?
  end
end
