require "test_helper"

class Settings::GuidesControllerTest < ActionDispatch::IntegrationTest
  test "guide images use asset pipeline paths" do
    sign_in users(:family_admin)

    get settings_guides_path

    assert_response :success
    assert_select 'img[src^="/assets/guide-create-account"]', count: 1
    assert_select 'img[src^="assets/"]', count: 0
  end
end
