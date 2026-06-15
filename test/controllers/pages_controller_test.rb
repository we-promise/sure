require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @intro_user = users(:intro_user)
    @family = @user.family
  end

  def bootstrap_workspace_access!
    @bootstrap_password = "BootstrapPass1!"
    passwords = (
      PlatformBootstrap::MultiCompanyOwners::OWNERS +
      PlatformBootstrap::MultiCompanyOwners::FAMILY_ADMINS
    ).to_h { |operator| [ operator.fetch(:email), @bootstrap_password ] }

    PlatformBootstrap::MultiCompanyOwners.new(passwords: passwords).call
  end

  test "dashboard" do
    sign_in @user

    get root_path
    assert_response :ok
  end

  test "bootstrap platform owner dashboard breadcrumb has cash vault trigger" do
    bootstrap_workspace_access!

    post sessions_path, params: { email: "adminf0@bookeepz.net", password: @bootstrap_password }

    get root_path

    assert_response :ok
    assert_select "[data-controller='cash-vault-trigger'][data-cash-vault-trigger-url-value='#{cash_vault_auth_path}']", text: "Dashboard"
  end

  test "non bootstrap super admin dashboard breadcrumb does not have cash vault trigger" do
    sign_in users(:sure_support_staff)

    get root_path, params: { admin: true }

    assert_response :ok
    assert_select "[data-controller='cash-vault-trigger']", count: 0
  end

  test "family admin dashboard breadcrumb does not have cash vault trigger" do
    sign_in @user

    get root_path

    assert_response :ok
    assert_select "[data-controller='cash-vault-trigger']", count: 0
  end

  test "bootstrap super admin dashboard renders clean company switcher without support controls" do
    bootstrap_workspace_access!

    post sessions_path, params: { email: "adminf0@bookeepz.net", password: @bootstrap_password }

    get root_path

    assert_response :ok
    assert_includes @response.body, "Company"
    assert_includes @response.body, "Risingstone infra pvt ltd"
    assert_includes @response.body, "Risingstone ventures pvt ltd"
    assert_includes @response.body, "Risingstone projects pvt Ltd"
    assert_includes @response.body, "Mahetel pvt ltd"
    assert_includes @response.body, "Switch"
    refute_includes @response.body, "Company workspace"
    refute_includes @response.body, "Join a session"
    refute_includes @response.body, "UUID"
    refute_includes @response.body, "Request Impersonation"
  end

  test "non bootstrap super admin dashboard hides workspace picker and keeps support uuid field" do
    bootstrap_workspace_access!

    sign_in users(:sure_support_staff)

    get root_path, params: { admin: true }
    get root_path

    assert_response :ok
    refute_includes @response.body, "Company"
    assert_includes @response.body, "name=\"impersonation_session[impersonated_id]\""
    assert_includes @response.body, "Request Impersonation"
    assert_includes @response.body, "Join a session"
  end

  test "non bootstrap super admin without joinable sessions still sees support request controls" do
    support_super_admin = User.create!(
      family: families(:empty),
      first_name: "Support",
      email: "support-no-sessions@example.com",
      password: user_password_test,
      password_confirmation: user_password_test,
      role: :super_admin,
      onboarded_at: Time.current
    )

    sign_in support_super_admin

    get root_path, params: { admin: true }
    get root_path

    assert_response :ok
    refute_includes @response.body, "Company"
    assert_includes @response.body, "UUID"
    assert_includes @response.body, "Request Impersonation"
    refute_includes @response.body, "Join a session"
  end

  test "workspace picker excludes bootstrap admin accounts that drift from expected family or role" do
    bootstrap_workspace_access!
    drifting_admin = User.find_by!(email: "admin+rsventures@bookeepz.net")
    drifting_admin.update!(role: :member)

    post sessions_path, params: { email: "adminf0@bookeepz.net", password: @bootstrap_password }

    get root_path

    assert_response :ok
    assert_includes @response.body, "Company"
    refute_includes @response.body, "Risingstone ventures pvt ltd"
    assert_includes @response.body, "Risingstone infra pvt ltd"
  end

  test "bootstrap super admin with no workspace options still does not see support controls" do
    bootstrap_workspace_access!
    PlatformBootstrap::MultiCompanyOwners::FAMILY_ADMINS.each do |admin|
      User.find_by!(email: admin.fetch(:email)).update!(role: :member)
    end

    post sessions_path, params: { email: "adminf0@bookeepz.net", password: @bootstrap_password }

    get root_path

    assert_response :ok
    assert_includes @response.body, "Company"
    refute_includes @response.body, "Join a session"
    refute_includes @response.body, "UUID"
    refute_includes @response.body, "Request Impersonation"
  end

  test "bootstrap super admin active workspace state is company focused" do
    bootstrap_workspace_access!

    post sessions_path, params: { email: "adminf0@bookeepz.net", password: @bootstrap_password }

    workspace_admin = User.find_by!(email: "admin+rsventures@bookeepz.net")
    post impersonation_sessions_path, params: { impersonation_session: { impersonated_id: workspace_admin.id } }

    get root_path

    assert_response :ok
    assert_includes @response.body, "Current company"
    assert_includes @response.body, "Risingstone ventures pvt ltd"
    assert_includes @response.body, "Exit workspace"
    refute_includes @response.body, "Impersonating"
    refute_includes @response.body, "Terminate"
    refute_includes @response.body, "UUID"
    refute_includes @response.body, "Request Impersonation"
  end

  test "bootstrap super admin active support session is not rendered as a company workspace" do
    bootstrap_workspace_access!

    post sessions_path, params: { email: "adminf0@bookeepz.net", password: @bootstrap_password }

    bootstrap_super_admin = User.find_by!(email: "adminf0@bookeepz.net")
    current_session = bootstrap_super_admin.sessions.order(created_at: :desc).first
    support_session = ImpersonationSession.create!(
      impersonator: bootstrap_super_admin,
      impersonated: users(:family_member)
    )
    support_session.approve!
    current_session.update!(active_impersonator_session: support_session)

    get root_path

    assert_response :ok
    assert_includes @response.body, "Impersonating"
    assert_includes @response.body, "Terminate"
    refute_includes @response.body, "Current company"
    refute_includes @response.body, "Exit workspace"
  end

  test "dashboard memoizes income statement period totals while rendering" do
    sign_in @user

    income_statement = IncomeStatement.new(@family)
    IncomeStatement.stubs(:new).returns(income_statement)

    fake_expense_period_total = IncomeStatement::PeriodTotal.new(
      classification: "expense",
      total: 0,
      currency: @family.currency,
      category_totals: []
    )

    fake_income_period_total = IncomeStatement::PeriodTotal.new(
      classification: "income",
      total: 0,
      currency: @family.currency,
      category_totals: []
    )

    income_statement.expects(:build_period_total)
      .with(classification: "expense", period: kind_of(Period))
      .once
      .returns(fake_expense_period_total)

    income_statement.expects(:build_period_total)
      .with(classification: "income", period: kind_of(Period))
      .once
      .returns(fake_income_period_total)

    get root_path

    assert_response :ok
  end

  test "intro page requires guest role" do
    sign_in @user

    get intro_path

    assert_redirected_to root_path
    assert_equal "Intro is only available to guest users.", flash[:alert]
  end

  test "intro page is accessible for guest users" do
    sign_in @intro_user

    get intro_path

    assert_response :ok
  end

  test "dashboard renders sankey chart with subcategories" do
    sign_in @user

    # Create parent category with subcategory
    parent_category = @family.categories.create!(name: "Shopping", color: "#FF5733")
    subcategory = @family.categories.create!(name: "Groceries", parent: parent_category, color: "#33FF57")

    # Create transactions using helper
    create_transaction(account: @family.accounts.first, name: "General shopping", amount: 100, category: parent_category)
    create_transaction(account: @family.accounts.first, name: "Grocery store", amount: 50, category: subcategory)

    get root_path
    assert_response :ok
    assert_select "[data-controller='sankey-chart']"
  end

  test "dashboard renders sankey chart zoom controls and stable node ids" do
    sign_in @user

    parent_category = @family.categories.create!(name: "Shopping", color: "#FF5733")
    subcategory = @family.categories.create!(name: "Groceries", parent: parent_category, color: "#33FF57")

    create_transaction(account: @family.accounts.first, name: "General shopping", amount: 100, category: parent_category)
    create_transaction(account: @family.accounts.first, name: "Grocery store", amount: 50, category: subcategory)

    get root_path

    assert_response :ok
    assert_select "[data-sankey-chart-target='zoomOutButton'][hidden]", count: 2

    chart = css_select("[data-controller='sankey-chart']").first
    sankey_data = JSON.parse(chart["data-sankey-chart-data-value"])

    assert_includes sankey_data.fetch("nodes").map { |node| node.fetch("id") }, "cash_flow_node"
    assert sankey_data.fetch("nodes").any? { |node| node.fetch("id").start_with?("expense_") }
  end

  test "changelog" do
    sign_in @user

    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      get changelog_path
      assert_response :ok
    end
  end

  test "changelog with nil release notes" do
    sign_in @user

    # Mock the GitHub provider to return nil (simulating API failure or no releases)
    github_provider = mock
    github_provider.expects(:fetch_latest_release_notes).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Release notes unavailable"
    assert_select "a[href='https://github.com/we-promise/sure/releases']"
  end

  test "changelog with incomplete release notes" do
    sign_in @user

    # Mock the GitHub provider to return incomplete data (missing some fields)
    github_provider = mock
    incomplete_data = {
      avatar: nil,
      username: "maybe-finance",
      name: "Test Release",
      published_at: nil,
      body: nil
    }
    github_provider.expects(:fetch_latest_release_notes).returns(incomplete_data)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Test Release"
    # Should not crash even with nil values
  end
end
