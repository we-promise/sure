require "test_helper"

class PocketsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
    @pocket = pockets(:emergency_fund)
  end

  test "index redirects to account pockets tab" do
    get account_pockets_url(@account)
    assert_redirected_to account_path(@account, tab: :pockets)
  end

  test "new returns success" do
    get new_account_pocket_url(@account)
    assert_response :success
  end

  test "create pocket with valid params" do
    assert_difference "Pocket.count", 1 do
      post account_pockets_url(@account), params: {
        pocket: { name: "New Pocket", allocated_amount: 200 }
      }
    end
    assert_redirected_to account_path(@account, tab: :pockets)
  end

  test "create pocket with auto-fill tag" do
    tag = tags(:two)
    assert_difference "Pocket.count", 1 do
      post account_pockets_url(@account), params: {
        pocket: { name: "Tagged Pocket", allocated_amount: 100, tag_id: tag.id }
      }
    end
    created = @account.pockets.find_by!(name: "Tagged Pocket")
    assert_equal tag.id, created.tag_id
  end

  test "create pocket with invalid params returns unprocessable" do
    assert_no_difference "Pocket.count" do
      post account_pockets_url(@account), params: {
        pocket: { name: "", allocated_amount: 200 }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create pocket exceeding balance returns unprocessable" do
    assert_no_difference "Pocket.count" do
      post account_pockets_url(@account), params: {
        pocket: { name: "Too Big", allocated_amount: 10_000 }
      }
    end
    assert_response :unprocessable_entity
  end

  test "edit returns success" do
    get edit_account_pocket_url(@account, @pocket)
    assert_response :success
  end

  test "update pocket with valid params" do
    patch account_pocket_url(@account, @pocket), params: {
      pocket: { name: "Renamed", allocated_amount: 800 }
    }
    assert_redirected_to account_path(@account, tab: :pockets)
    assert_equal "Renamed", @pocket.reload.name
    assert_equal 800, @pocket.reload.allocated_amount
  end

  test "destroy pocket" do
    assert_difference "Pocket.count", -1 do
      delete account_pocket_url(@account, @pocket)
    end
    assert_redirected_to account_path(@account, tab: :pockets)
  end

  test "cannot access pockets of another family account" do
    sign_in users(:empty)
    get account_pockets_url(@account)
    assert_response :not_found
  end
end
