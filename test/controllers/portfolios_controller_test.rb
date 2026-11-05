require "test_helper"

class PortfoliosControllerTest < ActionDispatch::IntegrationTest
  include SqlQueryCapture

  setup do
    @user = users(:family_admin)
    @family = @user.family
    enable_preview(@user)
    sign_in @user
    ensure_tailwind_build
  end

  test "redirects users without preview access to the dashboard" do
    disable_preview(@user)

    get portfolio_path

    assert_redirected_to root_path
    assert_equal I18n.t("preview.not_enabled"), flash[:alert]
  end

  # The class-level gate covers every action, so the one endpoint that writes
  # cannot save preferences for a page its caller is not allowed to see.
  test "preference writes are preview-gated like the page" do
    disable_preview(@user)

    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts] } },
      as: :json

    assert_redirected_to root_path
    assert_nil @user.reload.preferences["portfolio_section_order"]
  end

  test "a request the gate turns away does not save its period as the user's default" do
    disable_preview(@user)
    @user.update!(default_period: "last_30_days")

    get portfolio_path(period: "last_5_years")

    assert_redirected_to root_path
    assert_equal "last_30_days", @user.reload.default_period
  end

  test "renders the hub, its turbo frame and the accounts section" do
    get portfolio_path

    assert_response :success
    assert_select "h1", text: I18n.t("portfolios.show.title")
    assert_select "turbo-frame#portfolio_sections"
    assert_equal %w[accounts], css_select("[data-section-key]").map { |node| node["data-section-key"] }
  end

  test "the period picker reflects the requested period" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    # DS::MenuItem marks the current row with role=menuitemradio + aria-checked
    # (not aria-current), so that is what the picker's selection looks like.
    assert_select "a[href=?][aria-checked=?]", portfolio_path(period: "last_5_years"), "true"
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "5Y")
    assert_equal "last_5_years", @user.reload.default_period
  end

  # The picker shares the heading's row, and that row is the frame's first
  # child, so the first section follows it one gap below the heading.
  test "the period picker shares the heading's row, directly above the sections" do
    get portfolio_path(period: "last_5_years")

    assert_response :success
    assert_select "turbo-frame#portfolio_sections > div:first-child > header h1",
      text: I18n.t("portfolios.show.title")
    assert_select "turbo-frame#portfolio_sections > div:first-child > header + div[data-controller='DS--menu']" do
      assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "5Y")
    end
    assert_select "turbo-frame#portfolio_sections > div:first-child + div[role=list]"
  end

  test "an unknown period falls back rather than erroring" do
    get portfolio_path(period: "not_a_period")

    assert_response :success
    assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: "30D")
  end

  test "shows an empty state with an add-account link when the family has no investment accounts" do
    user = users(:empty)
    enable_preview(user)
    sign_in user
    assert_empty InvestmentStatement.new(user.family, user: user).investment_accounts

    get portfolio_path

    assert_response :success
    assert_match I18n.t("portfolios.empty_state.title"), response.body
    assert_select "a[href=?]", new_account_path
    assert_select "turbo-frame#portfolio_sections", count: 0
    assert_select "[data-section-key]", count: 0
  end

  test "saves the section order and collapsed set under the portfolio namespace only" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts], portfolio_collapsed_sections: { accounts: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
    assert @user.section_collapsed?("portfolio", "accounts")
    assert_nil @user.preferences["reports_section_order"]
    assert_nil @user.preferences["reports_collapsed_sections"]
  end

  test "drops preference keys that are not the portfolio's own" do
    patch update_preferences_portfolio_path,
      params: { preferences: { reports_section_order: %w[x] } },
      as: :json

    assert_response :ok
    assert_nil @user.reload.preferences["reports_section_order"]
  end

  # `kpis` is a real portfolio section that has not shipped here: a key the
  # registry does not list yet is ignored exactly like an invented one.
  test "drops section keys the registry does not know, in both shapes" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[kpis nonsense accounts], portfolio_collapsed_sections: { accounts: true, kpis: true, nonsense: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
    assert_equal({ "accounts" => true }, @user.preferences["portfolio_collapsed_sections"],
      "an unknown key must not be written into the user's preferences")
  end

  test "deduplicates the saved order, first occurrence winning" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_section_order: %w[accounts accounts] } },
      as: :json

    assert_response :ok
    assert_equal %w[accounts], @user.reload.preferences["portfolio_section_order"]
  end

  test "a collapsed payload that is not an object is dropped rather than raised on" do
    patch update_preferences_portfolio_path,
      params: { preferences: { portfolio_collapsed_sections: "true", portfolio_section_order: %w[accounts] } },
      as: :json

    assert_response :ok
    @user.reload
    assert_nil @user.preferences["portfolio_collapsed_sections"]
    assert_equal %w[accounts], @user.preferences["portfolio_section_order"]
  end

  test "renders sections collapsed where the user left them" do
    get portfolio_path
    assert_select "[data-section-key=accounts][data-reports-section-collapsed-value=?]", "false"

    @user.update_section_preferences("portfolio", collapsed: { "accounts" => true })
    get portfolio_path

    assert_response :success
    assert_select "[data-section-key=accounts][data-reports-section-collapsed-value=?]", "true"
    assert_select "[data-section-key=accounts] button[aria-expanded=?]", "false"
  end

  test "the sortable container posts to the portfolio endpoint under its own namespace" do
    get portfolio_path

    assert_response :success
    assert_select "[data-controller~=sortable-list][data-sortable-list-url-value=?][data-sortable-list-param-value=?]",
                  update_preferences_portfolio_path, "preferences.portfolio_section_order"
    assert_select "[data-section-key=accounts][data-reports-section-url-value=?][data-reports-section-preference-key-value=?]",
                  update_preferences_portfolio_path, "portfolio"
  end

  test "the nav shows Portfolio on desktop only, and never without the preview flag" do
    get portfolio_path

    assert_response :success
    assert_select "ul li a[href=?]", portfolio_path, minimum: 1
    assert_select "nav[data-viewport-target=bottomNav] a[href=?]", portfolio_path, count: 0

    disable_preview(@user)
    get root_path

    assert_response :success
    assert_select "a[href=?]", portfolio_path, count: 0
  end

  # Portfolio is the only desktop-only entry, so every other item still
  # reaches both bars: the mobile bar is the desktop rail without Portfolio,
  # plus the mobile-only Assistant.
  test "every other nav item still renders in both bars" do
    get root_path
    assert_response :success

    desktop = css_select("ul li a").map { |link| link["href"] }
    mobile = css_select("nav[data-viewport-target=bottomNav] a").map { |link| link["href"] }

    assert_includes desktop, portfolio_path
    assert_equal desktop - [ portfolio_path ], mobile - [ chats_path ]
    assert_includes mobile, chats_path if @family.assistant_enabled?
  end

  test "accounts grid links every countable investment account to its holdings tab and skips excluded shares" do
    other = users(:family_member)
    shared = @family.accounts.create!(name: "Shared brokerage", balance: 500, currency: "USD", accountable: Investment.new, owner: other)
    shared.share_with!(@user, permission: "read_only", include_in_finances: false)

    get portfolio_path
    assert_response :success

    assert_select "#portfolio-accounts a[href=?]", account_path(accounts(:investment), tab: "holdings")
    assert_select "#portfolio-accounts a[href=?]", account_path(shared, tab: "holdings"), count: 0
    assert_equal InvestmentStatement.new(@family, user: @user).investment_accounts.count, css_select("#portfolio-accounts a").size
  end

  # Each card's logo falls back to its provider's, read through
  # AccountProvider#provider, so the provider records are loaded with the
  # accounts rather than once per card.
  test "the accounts grid loads provider-linked accounts without a query per card" do
    link_investment_account(0)
    one = provider_queries { get portfolio_path }

    link_investment_account(1)
    link_investment_account(2)
    three = provider_queries { get portfolio_path }

    assert_response :success
    assert_select "#portfolio-accounts a", minimum: 3
    assert_equal one, three, "loading the linked accounts' providers grew with the number of cards"
  end

  private
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => false))
    end

    def link_investment_account(index)
      account = @family.accounts.create!(name: "Linked brokerage #{index}", balance: 1_000, currency: "USD",
                                         accountable: Investment.new, owner: @user)
      provider = LunchflowAccount.create!(lunchflow_item: lunchflow_items(:one), account_id: "lf_portfolio_#{index}",
                                          name: account.name, currency: "USD")
      AccountProvider.create!(account: account, provider: provider)
    end

    def provider_queries(&block)
      capture_sql_queries(&block).count { |sql| sql.include?(%(FROM "lunchflow_accounts")) }
    end
end
