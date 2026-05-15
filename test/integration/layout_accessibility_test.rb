require "test_helper"

class LayoutAccessibilityTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "application layout renders skip-link pointing at #main and a <main> with id=\"main\"" do
    get root_path
    assert_response :ok

    skip_text = I18n.t("layouts.application.skip_to_main")

    assert_select "a[href=\"#main\"]", text: skip_text
    assert_select "main#main"
  end

  test "settings layout renders skip-link pointing at #main and a <main> with id=\"main\"" do
    get settings_profile_path
    assert_response :ok

    skip_text = I18n.t("layouts.application.skip_to_main")

    assert_select "a[href=\"#main\"]", text: skip_text
    assert_select "main#main"
  end
end
