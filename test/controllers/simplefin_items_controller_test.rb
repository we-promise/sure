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
    assert_redirected_to accounts_path
  end

  test "should get edit" do
    @simplefin_item.update!(status: :requires_update)
    get edit_simplefin_item_url(@simplefin_item)
    assert_response :success
  end

  test "should update simplefin item with valid token" do
    @simplefin_item.update!(status: :requires_update)
    
    # Mock the SimpleFin provider
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with("valid_token").returns("https://example.com/new_access")
    Provider::Simplefin.expects(:new).returns(mock_provider)
    
    # Mock the new item creation
    @family.expects(:create_simplefin_item!).with(
      setup_token: "valid_token",
      item_name: @simplefin_item.name
    ).returns(@simplefin_item)
    
    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "valid_token" }
    }
    
    assert_redirected_to accounts_path
    assert_match(/updated successfully/, flash[:notice])
  end

  test "should handle update with invalid token" do
    @simplefin_item.update!(status: :requires_update)
    
    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "" }
    }
    
    assert_response :unprocessable_entity
    assert_includes response.body, "Please enter a SimpleFin setup token"
  end
end
