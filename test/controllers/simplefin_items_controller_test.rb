require "test_helper"

class SimplefinItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test Connection",
      access_url: "https://example.com/test_access"
    )
  end

  test "should get index" do
    get simplefin_items_url
    assert_response :success
    assert_includes response.body, @simplefin_item.name
  end

  test "should get new" do
    get new_simplefin_item_url
    assert_response :success
  end

  test "should show simplefin item" do
    get simplefin_item_url(@simplefin_item)
    assert_response :success
  end

  test "should destroy simplefin item" do
    assert_difference("SimplefinItem.count", 0) do # doesn't actually delete immediately
      delete simplefin_item_url(@simplefin_item)
    end

    assert_redirected_to simplefin_items_path
    @simplefin_item.reload
    assert @simplefin_item.scheduled_for_deletion?
  end

  test "should sync simplefin item" do
    post sync_simplefin_item_url(@simplefin_item)
    assert_redirected_to simplefin_item_path(@simplefin_item)
    assert_equal "Sync started", flash[:notice]
  end
end
