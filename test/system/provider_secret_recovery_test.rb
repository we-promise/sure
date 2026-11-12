require "application_system_test_case"

class ProviderSecretRecoveryTest < ApplicationSystemTestCase
  test "saving other fields preserves an unreadable credential and explicit deletion clears it" do
    user = users(:family_admin)
    user.update!(role: :super_admin)
    user.family.update!(auto_sync_on_login: false)
    envelope = { Setting::DynamicSecret::MARKER => 1, "ciphertext" => "synthetic-corrupt-ciphertext" }
    Setting[:plaid_client_id] = "synthetic-client"
    Setting.upsert({ var: "dynamic:plaid_secret", value: envelope.to_yaml }, unique_by: :var)
    original_config = Rails.application.config.plaid
    Rails.application.config.plaid = nil

    sign_in user
    visit settings_providers_path
    find("details", text: I18n.t("settings.providers.meta.unreadable_secret")).find("summary").click

    form_selector = "form:has(input[name='setting[plaid_secret]'])"
    within form_selector do
      fill_in "setting_plaid_client_id", with: "changed-client"
      click_button I18n.t("settings.providers.provider_form.save_and_connect")
    end

    assert_current_path settings_providers_path
    assert_text I18n.t("settings.providers.update.updated_successfully")
    find("details", text: I18n.t("settings.providers.meta.unreadable_secret")).find("summary").click
    assert_field "setting_plaid_client_id", with: "changed-client"
    assert_equal envelope, Setting.find_by!(var: "dynamic:plaid_secret").value

    within form_selector do
      check "setting_clear_plaid_secret"
      click_button I18n.t("settings.providers.provider_form.save_and_connect")
    end

    assert_current_path settings_providers_path
    assert_no_selector "#setting_clear_plaid_secret"
    assert_not Setting.key?(:plaid_secret)
  ensure
    Rails.application.config.plaid = original_config
  end
end
