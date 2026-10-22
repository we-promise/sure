require "application_system_test_case"

class ProviderFrameRedirectTest < ApplicationSystemTestCase
  test "an ambiguous Kraken connection leaves the modal and shows its alert" do
    family = families(:dylan_family)
    family.update!(auto_sync_on_login: false)
    family.kraken_items.create!(
      name: "Second Kraken",
      api_key: "second-key",
      api_secret: "second-secret"
    )
    sign_in users(:family_admin)
    visit settings_preferences_path

    # Open the actual provider endpoint with the same frame target as Add Account.
    execute_script(<<~JS)
      const link = document.createElement("a");
      link.id = "open-kraken-setup";
      link.href = #{select_accounts_kraken_items_path.to_json};
      link.dataset.turboFrame = "modal";
      link.textContent = "Open Kraken setup";
      link.style.cssText = "position: fixed; top: 0; left: 0; z-index: 100;";
      document.body.append(link);
    JS

    find("#open-kraken-setup").click

    assert_current_path settings_providers_path
    assert_selector "#notification-tray", text: I18n.t("kraken_items.select_accounts.select_connection")
  end
end
