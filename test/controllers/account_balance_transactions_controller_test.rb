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
    assert_equal transaction_path(shared), body["items"].find { |item| item["id"] == shared.id }["url"]
    assert_equal false, body["truncated"]
    assert_equal @range[:start_date], body["covered_from"]
  end

  test "converts with the rate stored for each transaction's date, without asking the provider" do
    yen = @admin.family.accounts.create!(name: "Yen savings", owner: @admin, currency: "JPY", balance: 0, accountable: Depository.new)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 10.days.ago.to_date, rate: 0.006)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 3.days.ago.to_date, rate: 0.007)
    early = create_transaction(account: yen, amount: 1_000, currency: "JPY", name: "Early", date: 5.days.ago.to_date)
    late = create_transaction(account: yen, amount: 1_000, currency: "JPY", name: "Late", date: 1.day.ago.to_date)
    ExchangeRate.expects(:find_or_fetch_rate).never

    sign_in @admin
    get dashboard_account_balance_transactions_path, params: @range

    items = response.parsed_body["items"].index_by { |i| i["id"] }
    assert_equal(-6.0, items[early.id]["amount"])
    assert_equal(-7.0, items[late.id]["amount"])
  end

  test "a transaction without a usable exchange rate has no converted amount, never a 1:1 one" do
    yen = @admin.family.accounts.create!(name: "Yen savings", owner: @admin, currency: "JPY", balance: 0, accountable: Depository.new)
    entry = create_transaction(account: yen, amount: 30_000, currency: "JPY", name: "Yen deposit", date: 1.day.ago.to_date)

    sign_in @admin
    get dashboard_account_balance_transactions_path, params: @range

    item = response.parsed_body["items"].find { |i| i["id"] == entry.id }
    assert_nil item["amount"], "left out of totals, like the chart leaves the account out"
    assert_includes item["display"], "30,000"
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

  test "at the cap, keeps the last day when the next row is from an older day" do
    @admin.family.accounts.where.not(owner: nil).find_each { |account| account.update_column(:status, "disabled") }
    account = @admin.family.accounts.create!(name: "Cap test", owner: @admin, currency: "USD", balance: 0, accountable: Depository.new)
    complete_day = 1.day.ago.to_date
    3.times { |i| create_transaction(account: account, amount: 1 + i, date: complete_day, name: "Day #{i}") }
    create_transaction(account: account, amount: 9, date: 3.days.ago.to_date, name: "Older")

    sign_in @admin
    with_limit(3) { get dashboard_account_balance_transactions_path, params: { start_date: 5.days.ago.to_date.iso8601, end_date: Date.current.iso8601 } }

    body = response.parsed_body
    assert body["truncated"]
    assert_equal 3, body["items"].size, "the cap holds the whole day"
    assert_equal complete_day.iso8601, body["covered_from"]
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
