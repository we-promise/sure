require "test_helper"

class LunchflowItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "invalid non-Turbo create redirects instead of rendering a missing template" do
    assert_no_difference "LunchflowItem.count" do
      post lunchflow_items_url, params: {
        lunchflow_item: {
          name: "Invalid Lunchflow connection",
          api_key: ""
        }
      }
    end

    assert_redirected_to accounts_path
    assert_match "Api key can't be blank", flash[:alert]
  end
end
