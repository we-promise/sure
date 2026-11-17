require "test_helper"

# The Bank sync drawer's Lunch Flow form must not render the stored API key.
class LunchflowItemsSecretFieldTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "the connect form does not render the stored API key" do
    lunchflow = lunchflow_items(:one)

    get connect_form_settings_providers_path(provider_key: "lunchflow")

    assert_response :success
    assert lunchflow.api_key.present?
    assert_select "form[action=?] input[name=?]", lunchflow_item_path(lunchflow), "lunchflow_item[api_key]" do |inputs|
      assert_nil inputs.first["value"]
    end
    assert_not_includes response.body, lunchflow.api_key
  end
end
