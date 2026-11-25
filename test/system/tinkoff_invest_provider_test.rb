require "application_system_test_case"

class TinkoffInvestProviderTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    login_as @user
  end

  test "configures T-Invest provider in settings, links discovered account, and displays requires_update state" do
    visit settings_providers_path

    find("a[href='#{connect_form_settings_providers_path(provider_key: "tinkoff_invest")}']").click
    within "#tinkoff_invest-providers-panel" do
      fill_in I18n.t("settings.providers.tinkoff_invest_panel.api_key_label"), with: "t.system-test-token"
      select I18n.t("settings.providers.tinkoff_invest_panel.environment_sandbox"),
        from: I18n.t("settings.providers.tinkoff_invest_panel.environment_label")
      page.save_screenshot(Rails.root.join("tmp", "tinkoff-settings-configure.png"))
      click_button I18n.t("settings.providers.tinkoff_invest_panel.save_configuration")
    end

    assert_current_path accounts_path
    item = @family.tinkoff_invest_items.sole
    assert_equal "sandbox", item.environment

    broker = item.tinkoff_invest_accounts.create!(
      name: "Main Brokerage",
      tinkoff_invest_account_id: "acct-system-1",
      account_type: "ACCOUNT_TYPE_TINKOFF",
      currency: "RUB",
      current_balance: 250_000,
      cash_balance: 25_000
    )
    item.update!(pending_account_setup: true)

    visit accounts_path
    card = find("##{ActionView::RecordIdentifier.dom_id(item)}")
    scroll_to(card, align: :center)
    page.save_screenshot(Rails.root.join("tmp", "tinkoff-accounts-card.png"))

    within card do
      click_link I18n.t("tinkoff_invest_items.tinkoff_invest_item.setup_accounts")
    end
    assert_text I18n.t("tinkoff_invest_items.setup_accounts.dialog_title")
    assert_text "Main Brokerage"
    page.save_screenshot(Rails.root.join("tmp", "tinkoff-setup-accounts.png"))

    click_button I18n.t("tinkoff_invest_items.setup_accounts.buttons.create_selected_accounts")
    assert_current_path accounts_path
    assert broker.reload.current_account.present?

    item.update!(status: :requires_update, pending_account_setup: false)
    visit settings_providers_path
    find("summary", text: I18n.t("providers.tinkoff_invest.name")).click
    within "#tinkoff_invest-providers-panel" do
      assert_text I18n.t("settings.providers.tinkoff_invest_panel.requires_update_title")
    end
    page.save_screenshot(Rails.root.join("tmp", "tinkoff-settings-requires-update.png"))
  end
end
