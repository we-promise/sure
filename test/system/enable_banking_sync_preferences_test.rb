require "application_system_test_case"

class EnableBankingSyncPreferencesTest < ApplicationSystemTestCase
  test "an admin can save the booked reference preference from its connection form" do
    user = users(:family_admin)
    item = user.family.enable_banking_items.create!(
      name: "Test bank connection",
      country_code: "ES",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
    )
    sign_in user
    visit connect_form_settings_providers_path(provider_key: "enable_banking")
    form_selector = "#sync_preferences_enable_banking_item_#{item.id}"
    label = I18n.t("settings.providers.enable_banking_panel.preserve_distinct_booked_references_label")

    within form_selector do
      check label, allow_label_click: true
      click_button I18n.t("settings.providers.enable_banking_panel.save_sync_preferences")
    end

    within form_selector do
      assert_checked_field label, visible: :all
    end
    assert item.reload.preserve_distinct_booked_references?

    within form_selector do
      uncheck label, allow_label_click: true
      click_button I18n.t("settings.providers.enable_banking_panel.save_sync_preferences")
    end

    within form_selector do
      assert_unchecked_field label, visible: :all
    end
    assert_not item.reload.preserve_distinct_booked_references?
  end
end
