require "test_helper"

class LocationSearchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get location_searches_url(q: "Malaga")

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end
end
