# frozen_string_literal: true

require "test_helper"

class Trading212ItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "select accounts leaves the Add Account modal for Settings at the top level" do
    families(:dylan_family).trading212_items.update_all(scheduled_for_deletion: true)

    get select_accounts_trading212_items_url, headers: { "Turbo-Frame" => "modal" }

    # A redirect would be followed inside the frame and the flash lost.
    assert_response :success
    assert_select "turbo-frame#modal turbo-stream[action=redirect][target=?]", settings_providers_path
    assert_equal I18n.t("trading212_items.select_accounts.not_configured"), flash[:alert]
  end
end
