require "test_helper"

class TurboNativeLayoutTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  test "applies turbo native layout for native user agents" do
    sign_in @user

    get root_url, headers: { "HTTP_USER_AGENT" => "Turbo Native iOS" }

    assert_response :success
    assert_select 'meta[name="turbo-native"][content="true"]'
    assert_select '[data-controller="turbo-native-bridge"]'
  end

  test "web layout remains unchanged for standard browsers" do
    sign_in @user

    get root_url

    assert_response :success
    assert_select 'meta[name="turbo-native"]', false
    assert_select '[data-controller="turbo-native-bridge"]', false
  end
end
