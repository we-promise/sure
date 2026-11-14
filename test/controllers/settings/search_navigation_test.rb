require "test_helper"

class Settings::SearchNavigationTest < ActionDispatch::IntegrationTest
  test "settings pages render a search field backed by every page the user can open" do
    sign_in users(:family_admin)

    get settings_profile_path

    assert_response :success
    assert_select "input[type=search][data-settings-search-target=input][data-hotkey='/']"
    assert_includes search_labels, I18n.t("settings.settings_nav.security_label")
    assert_includes search_labels, I18n.t("settings.settings_nav.bank_sync_label")
    assert_includes search_labels, I18n.t("settings.settings_nav.api_keys_label")
  end

  test "search results link to the page and name its section" do
    sign_in users(:family_admin)

    get settings_profile_path

    assert_select "[data-settings-search-target=item] a[href='#{settings_security_path}']", text: /#{I18n.t("settings.settings_nav.security_label")}/ do |links|
      assert_match I18n.t("settings.settings_nav.general_section_title"), links.first.text
    end
  end

  test "members are not offered admin-only pages" do
    sign_in users(:family_member)

    get settings_profile_path

    assert_response :success
    assert_includes search_labels, I18n.t("settings.settings_nav.security_label")
    assert_not_includes search_labels, I18n.t("settings.settings_nav.bank_sync_label")
    assert_not_includes search_labels, I18n.t("settings.settings_nav.api_keys_label")
    assert_not_includes search_labels, I18n.t("settings.settings_nav.statement_vault_label")
  end

  test "pages whose settings can be searched are handed to the controller" do
    sign_in users(:family_admin)

    get settings_profile_path

    pages = JSON.parse(css_select("[data-controller~=settings-search]").first["data-settings-search-pages-value"])
    assert_includes pages, { "path" => settings_security_path, "label" => I18n.t("settings.settings_nav.security_label") }
    assert_includes pages, { "path" => settings_preferences_path, "label" => I18n.t("settings.settings_nav.preferences_label") }
    assert_not_includes pages.map { |page| page["path"] }, categories_path
  end

  test "the search index is scoped to the signed-in user" do
    sign_in users(:family_member)

    get settings_profile_path

    assert_select "[data-controller~=settings-search][data-settings-search-scope-value='#{users(:family_member).id}:#{I18n.locale}']"
  end

  test "members are not handed admin-only pages to search" do
    sign_in users(:family_member)

    get settings_profile_path

    pages = JSON.parse(css_select("[data-controller~=settings-search]").first["data-settings-search-pages-value"])
    assert_not_includes pages.map { |page| page["path"] }, settings_api_keys_path
    assert_not_includes pages.map { |page| page["path"] }, settings_ai_prompts_path
  end

  private
    def search_labels
      css_select("[data-settings-search-target=item]").map { |item| item["data-search-label"] }
    end
end
