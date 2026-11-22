require "test_helper"

class AccountBalanceTransactionsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @range = { start_date: 1.year.ago.to_date.iso8601, end_date: 1.month.from_now.to_date.iso8601 }
  end

  test "requires a browser session even when an API key is supplied" do
    get dashboard_account_balance_transactions_path, params: @range, headers: { "X-Api-Key" => api_key.display_key }
    assert_redirected_to new_session_path
  end

  test "rejects a missing or reversed period" do
    sign_in @admin
    get dashboard_account_balance_transactions_path, params: { start_date: "2026-02-01", end_date: "2026-01-01" }
    assert_response :unprocessable_entity
    get dashboard_account_balance_transactions_path, params: { start_date: "yesterday", end_date: "2026-01-01" }
    assert_response :unprocessable_entity
  end

  test "returns transactions of accessible accounts only, newest first, in the chart's sign" do
    private_account = accounts(:investment)
    hidden = create_transaction(account: private_account, amount: 70, name: "Private trade fee", date: 2.days.ago.to_date)
    shared = create_transaction(account: accounts(:depository), amount: 25, name: "Shared groceries", date: 1.day.ago.to_date)
    assert_not_includes @member.accessible_accounts, private_account

    sign_in @member
    get dashboard_account_balance_transactions_path, params: @range

    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    ids = body["items"].map { |item| item["id"] }
    assert_includes ids, shared.id
    assert_not_includes ids, hidden.id
    assert_equal body["items"].map { |item| item["date"] }, body["items"].map { |item| item["date"] }.sort.reverse
    assert_equal(-25.0, body["items"].find { |item| item["id"] == shared.id }["amount"], "an outflow is a negative change")
    assert_equal false, body["truncated"]
    assert_equal @range[:start_date], body["covered_from"]
  end

  test "at the cap, drops the partially covered oldest day and says where coverage starts" do
    # Only this account's transactions, so the cut is predictable.
    @admin.family.accounts.where.not(owner: nil).find_each { |account| account.update_column(:status, "disabled") }
    account = @admin.family.accounts.create!(name: "Cap test", owner: @admin, currency: "USD", balance: 0, accountable: Depository.new)
    day = 3.days.ago.to_date
    3.times { |i| create_transaction(account: account, amount: 1 + i, date: day, name: "Old #{i}") }
    2.times { |i| create_transaction(account: account, amount: 5 + i, date: 1.day.ago.to_date, name: "New #{i}") }

    sign_in @admin
    with_limit(3) { get dashboard_account_balance_transactions_path, params: { start_date: day.iso8601, end_date: Date.current.iso8601 } }

    body = response.parsed_body
    assert body["truncated"]
    assert_equal (day + 1).iso8601, body["covered_from"]
    assert body["items"].none? { |item| item["date"] == day.iso8601 }, "an incomplete day is not returned"
    assert_equal 2, body["items"].count { |item| item["date"] == 1.day.ago.to_date.iso8601 }
  end

  private
    def api_key
      ApiKey.create!(user: @admin, name: "Lane Read", scopes: [ "read" ], display_key: "test_ro_#{SecureRandom.hex(8)}", source: "mobile")
    end

    def with_limit(limit)
      original = AccountBalanceTransactionsController::LIMIT
      silence_warnings { AccountBalanceTransactionsController.const_set(:LIMIT, limit) }
      yield
    ensure
      silence_warnings { AccountBalanceTransactionsController.const_set(:LIMIT, original) }
    end
end
