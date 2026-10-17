require "test_helper"

class Settings::AppearancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "shows the account list settings to preview users only" do
    get settings_appearance_path
    assert_select "select[name='user[account_grouping_sidebar]']"

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    get settings_appearance_path
    assert_select "select[name='user[account_grouping_sidebar]']", count: 0
  end

  test "stores a valid grouping dimension per view and drops unknown ones" do
    patch settings_appearance_path, params: { user: { account_grouping_sidebar: "institution", account_grouping_dashboard: "custom_group" } }
    assert_redirected_to settings_appearance_path

    @user.reload
    assert_equal "institution", @user.account_grouping_for(:sidebar)
    assert_equal "custom_group", @user.account_grouping_for(:dashboard)

    patch settings_appearance_path, params: { user: { account_grouping_sidebar: "name; drop table" } }
    @user.reload
    assert_nil @user.account_grouping_for(:sidebar)
    assert_equal "custom_group", @user.account_grouping_for(:dashboard)

    patch settings_appearance_path, params: { user: { account_grouping_dashboard: "" } }
    assert_nil @user.reload.account_grouping_for(:dashboard)
  end

  test "stores the first level per view and falls back to the account type" do
    patch settings_appearance_path, params: { user: { account_grouping_primary_sidebar: "institution", account_grouping_sidebar: "account_type" } }

    @user.reload
    assert_equal "institution", @user.account_grouping_primary_for(:sidebar)
    assert_equal "account_type", @user.account_grouping_for(:sidebar)
    assert_equal "account_type", @user.account_grouping_primary_for(:dashboard)

    patch settings_appearance_path, params: { user: { account_grouping_primary_sidebar: "bogus" } }
    assert_equal "account_type", @user.reload.account_grouping_primary_for(:sidebar)
  end

  test "a second level equal to the first level reads as none" do
    @user.update!(preferences: @user.preferences.merge(
      "account_grouping_primary" => { "sidebar" => "currency" },
      "account_grouping" => { "sidebar" => "currency" }
    ))

    assert_nil @user.account_grouping_for(:sidebar)
  end

  test "renders another first level in the sidebar and on the dashboard" do
    accounts(:depository).update!(institution_name: "ING")
    @user.update!(preferences: @user.preferences.merge("account_grouping_primary" => { "sidebar" => "institution", "dashboard" => "institution" }))

    get root_path

    assert_response :success
    assert_select "#account-sidebar-tabs", text: /ING/
    assert_select "#balance-sheet details[data-group-key^='asset_institution_']"
    assert_select "#balance-sheet details[data-group-key='depository']", count: 0
  end

  test "keeps assets and debts apart in the all tab when another first level leaves both unset" do
    @user.update!(preferences: @user.preferences.merge("account_grouping_primary" => { "sidebar" => "custom_group" }))
    none = I18n.t("account_grouping.none")

    get root_path

    assert_response :success
    sections = css_select("#account-sidebar-tabs [data-sidebar-classification]").map { |node| node["data-sidebar-classification"] }
    assert_equal %w[asset liability], sections.uniq
    %w[asset liability].each do |classification|
      assert_select "#account-sidebar-tabs [data-sidebar-classification='#{classification}'] [data-group-key^='#{classification}_custom_group_']", text: /#{none}/
    end
  end

  test "keeps the all tab flat when grouped by account type" do
    get root_path

    assert_response :success
    assert_select "#account-sidebar-tabs [data-sidebar-classification]", count: 0
  end

  test "keeps other preferences when saving the grouping" do
    @user.update!(preferences: @user.preferences.merge("always_expanded_account_groups" => [ "depository" ]))

    patch settings_appearance_path, params: { user: { account_grouping_sidebar: "currency" } }

    assert_equal [ "depository" ], @user.reload.always_expanded_account_groups
  end

  test "renames the custom group field and resets it when blank" do
    patch settings_appearance_path, params: { user: { custom_account_group_label: "  Purpose " } }
    assert_equal "Purpose", @user.reload.custom_account_group_label

    patch settings_appearance_path, params: { user: { custom_account_group_label: "" } }
    assert_equal I18n.t("account_grouping.dimensions.custom_group"), @user.reload.custom_account_group_label
  end

  test "renders the second level in the sidebar and on the dashboard" do
    accounts(:depository).update!(institution_name: "ING")
    @user.update!(preferences: @user.preferences.merge("account_grouping" => { "sidebar" => "institution", "dashboard" => "institution" }))

    get root_path

    assert_response :success
    assert_select "#account-sidebar-tabs [data-subgroup-key='ing']"
    assert_select "#balance-sheet [data-subgroup-key='ing']"
  end

  test "ignores the stored grouping without preview access" do
    accounts(:depository).update!(institution_name: "ING")
    @user.update!(preferences: @user.preferences.merge(
      "preview_features_enabled" => false,
      "account_grouping" => { "sidebar" => "institution", "dashboard" => "institution" }
    ))

    get root_path

    assert_response :success
    assert_select "[data-subgroup-key]", count: 0
  end
end
