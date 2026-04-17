require "test_helper"
require "cgi"

class PagesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @intro_user = users(:intro_user)
    @family = @user.family
  end

  test "dashboard" do
    get root_path
    assert_response :ok
  end

  test "dashboard renders sankey mode toggle links" do
    get root_path

    assert_response :ok
    assert_select "#cashflow-sankey-chart a[href*='sankey_mode=aggregate']", count: 1
    assert_select "#cashflow-sankey-chart a[href*='sankey_mode=split']", count: 1
  end

  test "intro page requires guest role" do
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

  test "dashboard shows transfer outflow in sankey for selected source account" do
    source_account = @family.accounts.create!(
      name: "Sankey Source Account",
      currency: @family.currency,
      balance: 2000,
      accountable: Depository.new
    )
    destination_account = @family.accounts.create!(
      name: "Sankey Credit Card",
      currency: @family.currency,
      balance: 800,
      accountable: CreditCard.new
    )

    Transfer::Creator.new(
      family: @family,
      source_account_id: source_account.id,
      destination_account_id: destination_account.id,
      date: Date.current,
      amount: 250
    ).create

    get root_path, params: { account_id: source_account.id }

    assert_response :ok
    sankey_data = extract_sankey_data
    assert_not_nil sankey_data

    cash_flow_idx = sankey_data["nodes"].index { |node| node["name"] == "Cash Flow" }
    destination_idx = sankey_data["nodes"].index { |node| node["name"] == "#{I18n.t("pages.dashboard.cashflow_sankey.to_label")} #{destination_account.name}" }

    assert_not_nil cash_flow_idx
    assert_not_nil destination_idx
    assert(
      sankey_data["links"].any? { |link| link["source"] == cash_flow_idx && link["target"] == destination_idx },
      "Expected a cash-flow outbound transfer link to the selected account's counterparty"
    )
  end

  test "dashboard shows transfer inflow in sankey for selected destination account" do
    source_account = @family.accounts.create!(
      name: "Sankey Checking",
      currency: @family.currency,
      balance: 2000,
      accountable: Depository.new
    )
    destination_account = @family.accounts.create!(
      name: "Sankey Card",
      currency: @family.currency,
      balance: 800,
      accountable: CreditCard.new
    )

    Transfer::Creator.new(
      family: @family,
      source_account_id: source_account.id,
      destination_account_id: destination_account.id,
      date: Date.current,
      amount: 300
    ).create

    get root_path, params: { account_id: destination_account.id }

    assert_response :ok
    sankey_data = extract_sankey_data
    assert_not_nil sankey_data

    source_idx = sankey_data["nodes"].index { |node| node["name"] == "#{I18n.t("pages.dashboard.cashflow_sankey.from_label")} #{source_account.name}" }
    cash_flow_idx = sankey_data["nodes"].index { |node| node["name"] == "Cash Flow" }

    assert_not_nil source_idx
    assert_not_nil cash_flow_idx
    assert(
      sankey_data["links"].any? { |link| link["source"] == source_idx && link["target"] == cash_flow_idx },
      "Expected an inbound transfer link from counterparty account to cash flow"
    )
  end

  test "dashboard split mode hides transfer nodes to reduce clutter" do
    source_account = @family.accounts.create!(
      name: "Sankey Split Source",
      currency: @family.currency,
      balance: 2000,
      accountable: Depository.new
    )
    destination_account = @family.accounts.create!(
      name: "Sankey Split Card",
      currency: @family.currency,
      balance: 800,
      accountable: CreditCard.new
    )

    Transfer::Creator.new(
      family: @family,
      source_account_id: source_account.id,
      destination_account_id: destination_account.id,
      date: Date.current,
      amount: 225
    ).create

    income_category = @family.categories.create!(name: "Split Overlay Income", color: "#0EA5E9")
    expense_category = @family.categories.create!(name: "Split Overlay Expense", color: "#F97316")
    create_transaction(account: source_account, amount: -400, category: income_category)
    create_transaction(account: destination_account, amount: 120, category: expense_category)

    get root_path, params: { sankey_mode: "split" }

    assert_response :ok
    sankey_data = extract_sankey_data
    assert_not_nil sankey_data

    transfer_prefixes = [
      I18n.t("pages.dashboard.cashflow_sankey.from_label"),
      I18n.t("pages.dashboard.cashflow_sankey.to_label")
    ]

    transfer_nodes = sankey_data["nodes"].select do |node|
      transfer_prefixes.any? { |prefix| node["name"].start_with?(prefix) }
    end

    assert_empty transfer_nodes, "Expected split mode to hide transfer helper nodes"

    assert(
      sankey_data["links"].any? do |link|
        source = sankey_data["nodes"][link["source"]]
        target = sankey_data["nodes"][link["target"]]
        source && target && source["name"] == source_account.name && target["name"] == destination_account.name
      end,
      "Expected split mode to include net account-to-account transfer links"
    )
  end

  test "dashboard split mode shares expense category nodes across accounts" do
    shared_category = @family.categories.create!(
      name: "Split Shared Expense Category",
      color: "#3355FF"
    )
    first_account = @family.accounts.create!(
      name: "Split Category Account One",
      currency: @family.currency,
      balance: 2200,
      accountable: Depository.new
    )
    second_account = @family.accounts.create!(
      name: "Split Category Account Two",
      currency: @family.currency,
      balance: 1600,
      accountable: Depository.new
    )

    create_transaction(account: first_account, amount: 120, category: shared_category)
    create_transaction(account: second_account, amount: 80, category: shared_category)

    get root_path, params: { sankey_mode: "split" }

    assert_response :ok
    sankey_data = extract_sankey_data
    assert_not_nil sankey_data

    category_node_indices = sankey_data["nodes"].each_index.select do |index|
      sankey_data["nodes"][index]["name"] == shared_category.name
    end

    first_account_idx = sankey_data["nodes"].index { |node| node["name"] == first_account.name }
    second_account_idx = sankey_data["nodes"].index { |node| node["name"] == second_account.name }

    assert_equal 1, category_node_indices.size
    assert_not_nil first_account_idx
    assert_not_nil second_account_idx

    category_idx = category_node_indices.first
    assert(
      sankey_data["links"].any? { |link| link["source"] == first_account_idx && link["target"] == category_idx },
      "Expected first account to link to shared expense category"
    )
    assert(
      sankey_data["links"].any? { |link| link["source"] == second_account_idx && link["target"] == category_idx },
      "Expected second account to link to shared expense category"
    )
  end

  test "dashboard split mode keeps all expense categories visible" do
    account = @family.accounts.create!(
      name: "Split Expense Coverage Account",
      currency: @family.currency,
      balance: 5000,
      accountable: Depository.new
    )

    expense_categories = 6.times.map do |idx|
      @family.categories.create!(name: "Split Expense Category #{idx}", color: format("#AA%02X%02X", idx + 10, idx + 20))
    end

    expense_categories.each_with_index do |category, idx|
      create_transaction(
        account: account,
        amount: 30 + idx,
        category: category,
        date: Date.current - idx.days
      )
    end

    get root_path, params: { sankey_mode: "split" }

    assert_response :ok
    sankey_data = extract_sankey_data
    assert_not_nil sankey_data

    node_names = sankey_data["nodes"].map { |node| node["name"] }
    expense_categories.each do |category|
      assert_includes node_names, category.name
    end
  end

  test "changelog" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      get changelog_path
      assert_response :ok
    end
  end

  test "changelog with nil release notes" do
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

  private
    def extract_sankey_data
      chart = Nokogiri::HTML(response.body).at_css("[data-controller='sankey-chart']")
      return nil unless chart

      JSON.parse(CGI.unescapeHTML(chart["data-sankey-chart-data-value"]))
    end
end
