require "application_system_test_case"

class SaxoConnectionTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    Setting.saxo_app_key = "test-key"
    Setting.saxo_app_secret = "test-secret"
    login_as @user
  end

  test "preview connection form starts authorization without bank credential fields" do
    visit connect_form_settings_providers_path(provider_key: "saxo")
    assert_text I18n.t("saxo.description")
    assert_button I18n.t("saxo.connect")
    assert_no_field "login"
    assert_no_field "password"
  end

  test "an investment account can start a Saxo connection" do
    visit accounts_url
    click_on I18n.t("accounts.index.new_account")
    assert_selector "turbo-frame#modal[complete]", visible: :all
    click_link Investment.singular_display_name
    assert_selector "turbo-frame#modal[complete]", visible: :all
    click_link I18n.t("accounts.new.method_selector.link_with_provider", provider: "Saxo Bank")

    assert_selector "dialog:modal", text: I18n.t("saxo.description")
    assert_selector "dialog:modal", text: I18n.t("saxo.market_data_setup")
    assert_selector "dialog:modal form[action='#{saxo_items_path}'][method='post'][data-turbo='false']"
    assert_button I18n.t("saxo.connect")
  end

  test "an expired connection offers reconnection and creates the selected PEA account" do
    item = @user.family.saxo_items.create!(status: :requires_update)
    provider_account = item.saxo_accounts.create!(account_id: "123", name: "Saxo PEA", account_type: "PEA", currency: "EUR")
    visit saxo_item_path(item)
    assert_text(/#{Regexp.escape(I18n.t("saxo.reconnect_required"))}/i)
    assert_button I18n.t("saxo.reconnect")
    assert_selector "form[action='#{reconnect_saxo_item_path(item)}']"
    click_button I18n.t("saxo.link_account")
    assert_text I18n.t("saxo.account_linked")
    assert_equal "pea", provider_account.reload.account.investment.subtype
  end

  test "a failed authorization shows a recoverable error" do
    visit callback_saxo_items_path(state: "invalid", error: "access_denied")
    assert_text I18n.t("saxo.authorization_failed")
  end
end
