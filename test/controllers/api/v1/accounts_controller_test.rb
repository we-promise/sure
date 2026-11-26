# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin) # dylan_family user
    @other_family_user = users(:family_member)
    @other_family_user.update!(family: families(:empty))

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @other_family_user.api_keys.active.destroy_all
    @other_family_api_key = ApiKey.create!(
      user: @other_family_user,
      name: "Other Family Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "other_family_read_#{SecureRandom.hex(8)}"
    )
  end

  test "should require authentication" do
    get "/api/v1/accounts"
    assert_response :unauthorized

    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read_accounts scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to exercise the runtime insufficient-scope guard.
    api_key_without_read.save!(validate: false)

    get "/api/v1/accounts", params: {}, headers: api_headers(api_key_without_read)

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should return user's family accounts successfully" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have accounts array
    assert response_body.key?("accounts")
    assert response_body["accounts"].is_a?(Array)

    # Should have pagination metadata
    assert response_body.key?("pagination")
    assert response_body["pagination"].key?("page")
    assert response_body["pagination"].key?("per_page")
    assert response_body["pagination"].key?("total_count")
    assert response_body["pagination"].key?("total_pages")

    # All accounts should belong to user's family
    response_body["accounts"].each do |account|
      # We'll validate this by checking the user's family has these accounts
      family_account_names = @user.family.accounts.pluck(:name)
      assert_includes family_account_names, account["name"]
    end
  end

  test "should only return active accounts" do
    # Make one account inactive
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should not include the inactive account
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_not_includes account_names, inactive_account.name
  end

  test "reports the exclusion flag without hiding excluded account identities" do
    account = accounts(:depository)
    get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)
    assert_response :success
    assert_equal false, JSON.parse(response.body).fetch("exclude_from_reports")

    account.update!(exclude_from_reports: true)
    get "/api/v1/accounts", params: { per_page: 100 }, headers: api_headers(@api_key)
    assert_response :success
    row = JSON.parse(response.body).fetch("accounts").find { |item| item["id"] == account.id }
    assert_not_nil row
    assert_equal true, row.fetch("exclude_from_reports")

    get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)
    assert_response :success
    assert_equal true, JSON.parse(response.body).fetch("exclude_from_reports")
  end

  test "should include disabled accounts when requested" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts", params: { include_disabled: true }, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    account = response_body["accounts"].find { |account_data| account_data["id"] == inactive_account.id }
    assert_not_nil account
    assert_equal "disabled", account["status"]
  end

  test "should show active account" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal account.id, response_body["id"]
    assert_equal account.status, response_body["status"]
    assert_equal account.balance_money.format, response_body["balance"]
    assert_equal money_cents(account.balance_money), response_body["balance_cents"]
    assert_equal account.cash_balance_money.format, response_body["cash_balance"]
    assert_equal money_cents(account.cash_balance_money), response_body["cash_balance_cents"]
    assert_nullable_equal account.subtype, response_body["subtype"]
    assert response_body.key?("institution_name")
    assert response_body.key?("institution_domain")
    assert_nullable_equal account.institution_name, response_body["institution_name"]
    assert_nullable_equal account.institution_domain, response_body["institution_domain"]
    assert_equal account.created_at.iso8601, response_body["created_at"]
    assert_equal account.updated_at.iso8601, response_body["updated_at"]
  end

  test "should return 404 for unknown account on show" do
    get "/api/v1/accounts/#{SecureRandom.uuid}", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
  end

  test "should return 404 for malformed account id on show" do
    get "/api/v1/accounts/not-a-uuid", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
    assert_equal "Account not found", response_body["message"]
  end

  test "should require authentication on show" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}"

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read scope on show" do
    account = accounts(:depository)
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Show Key",
      scopes: [],
      source: "web",
      display_key: "no_read_show_#{SecureRandom.hex(8)}"
    )
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to exercise the runtime insufficient-scope guard.
    api_key_without_read.save!(validate: false)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(api_key_without_read)

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should hide disabled account by default on show" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts/#{inactive_account.id}", headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should show disabled account when requested" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts/#{inactive_account.id}",
        params: { include_disabled: true },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal inactive_account.id, response_body["id"]
    assert_equal "disabled", response_body["status"]
  end

  test "should expose subtype across account types" do
    expected_subtypes = {
      accounts(:depository) => "checking",
      accounts(:credit_card) => "credit_card",
      accounts(:investment) => "brokerage",
      accounts(:loan) => "mortgage",
      accounts(:property) => "single_family_home",
      accounts(:vehicle) => "sedan",
      accounts(:crypto) => "exchange",
      accounts(:other_asset) => "collectible",
      accounts(:other_liability) => "personal_debt"
    }

    expected_subtypes.each { |account, subtype| account.accountable.update!(subtype: subtype) }

    expected_subtypes.each do |account, subtype|
      get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

      assert_response :success
      assert_equal subtype, JSON.parse(response.body)["subtype"]
    end
  end

  test "should not return other family's accounts" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@other_family_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should return empty array since other family has no accounts in fixtures
    assert_equal [], response_body["accounts"]
    assert_equal 0, response_body["pagination"]["total_count"]
  end

  test "should handle pagination parameters" do
    # Test with pagination params
    get "/api/v1/accounts", params: { page: 1, per_page: 2 }, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should respect per_page limit
    assert response_body["accounts"].length <= 2
    assert_equal 1, response_body["pagination"]["page"]
    assert_equal 2, response_body["pagination"]["per_page"]
  end

  test "should return proper account data structure" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have at least one account from fixtures
    assert response_body["accounts"].length > 0

    account = response_body["accounts"].first

    # Check required fields are present
    required_fields = %w[id name balance balance_cents cash_balance cash_balance_cents currency classification account_type]
    required_fields.each do |field|
      assert account.key?(field), "Account should have #{field} field"
    end

    # Check data types
    assert account["id"].is_a?(String), "ID should be string (UUID)"
    assert account["name"].is_a?(String), "Name should be string"
    assert account["balance"].is_a?(String), "Balance should be string (money)"
    assert account["balance_cents"].is_a?(Integer), "Balance cents should be integer"
    assert account["cash_balance_cents"].is_a?(Integer), "Cash balance cents should be integer"
    assert account["currency"].is_a?(String), "Currency should be string"
    assert %w[asset liability].include?(account["classification"]), "Classification should be asset or liability"
  end

  test "should handle invalid pagination parameters gracefully" do
    # Test with invalid page number
    get "/api/v1/accounts", params: { page: -1, per_page: "invalid" }, headers: api_headers(@api_key)

    # Should still return success with default pagination
    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have pagination info (with defaults applied)
    assert response_body.key?("pagination")
    assert response_body["pagination"]["page"] >= 1
    assert response_body["pagination"]["per_page"] > 0
  end

  test "should sort accounts alphabetically" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should be sorted alphabetically by name
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_equal account_names.sort, account_names
  end

  test "create requires authentication" do
    post "/api/v1/accounts", params: { account: { name: "X", accountable_type: "Depository", balance: 1 } }
    assert_response :unauthorized
  end

  test "create is forbidden for a read-only key" do
    assert_no_difference "Account.count" do
      post_account({ name: "X", accountable_type: "Depository", balance: 1 }, key: @api_key)
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "create does not let a guest create accounts" do
    @user.update!(role: :guest)

    assert_no_difference "Account.count" do
      post_account({ name: "Guest account", accountable_type: "Depository", balance: 1 })
    end

    assert_response :forbidden
  end

  test "create makes a depository account owned by the key's user" do
    assert_difference -> { @user.family.accounts.count }, 1 do
      post_account({ name: "API Chequing", accountable_type: "depository", balance: "1250.50", currency: "CAD" })
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "API Chequing", body["name"]
    assert_equal "depository", body["account_type"]
    assert_equal "CAD", body["currency"]
    assert_equal 125_050, body["balance_cents"]

    account = @user.family.accounts.find(body["id"])
    assert_equal @user, account.owner
  end

  test "create accepts a zero balance" do
    post_account({ name: "Empty", accountable_type: "Depository", balance: "0" })

    assert_response :created
    assert_equal 0, JSON.parse(response.body)["balance_cents"]
  end

  test "create defaults the currency to the family currency" do
    post_account({ name: "Default Currency", accountable_type: "CreditCard", balance: 100 })

    assert_response :created
    assert_equal @user.family.currency, JSON.parse(response.body)["currency"]
    assert_equal "credit_card", JSON.parse(response.body)["account_type"]
  end

  test "create normalizes the currency code" do
    post_account({ name: "Euro account", accountable_type: "Depository", balance: 1, currency: "eur" })

    assert_response :created
    assert_equal "EUR", JSON.parse(response.body)["currency"]
  end

  test "create makes a loan with its terms and current balance" do
    post_account({
      name: "Car Lease",
      accountable_type: "Loan",
      balance: "48000.00",
      accountable_attributes: { initial_balance: "51000.00", start_date: "2026-06-03", interest_rate: "6.5", rate_type: "fixed", term_months: 36 }
    })

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "loan", body["account_type"]
    assert_equal "liability", body["classification"]
    assert_equal 4_800_000, body["balance_cents"]

    loan = @user.family.accounts.find(body["id"]).accountable
    assert_equal Date.new(2026, 6, 3), loan.start_date
    assert_equal 36, loan.term_months
    assert_in_delta 6.5, loan.interest_rate.to_f, 0.001
  end

  test "create keeps the entered balance for a loan that started earlier even after the initial sync" do
    perform_enqueued_jobs do
      post_account(loan_params(start_date: 1.year.ago.to_date.iso8601))
    end

    assert_response :created
    assert_equal 40_000, @user.family.accounts.find(JSON.parse(response.body)["id"]).reload.balance
  end

  test "create rejects a loan whose balance would be replaced by initial_balance on its start date" do
    assert_account_rejected(loan_params(start_date: Date.current.iso8601))
    assert_match(/initial_balance/, JSON.parse(response.body)["message"])
  end

  test "create accepts a loan starting today when balance equals initial_balance" do
    post_account(loan_params(balance: "50000", start_date: Date.current.iso8601))

    assert_response :created
    assert_equal 5_000_000, JSON.parse(response.body)["balance_cents"]
  end

  test "create keeps the property details the web form accepts" do
    post_account({
      name: "Cottage",
      accountable_type: "Property",
      balance: "350000",
      accountable_attributes: { year_built: 1987, area_value: 1450, area_unit: "sqft", cost_tag_id: tags(:one).id }
    })

    assert_response :created
    property = @user.family.accounts.find(JSON.parse(response.body)["id"]).accountable
    assert_equal 1987, property.year_built
    assert_equal 1450, property.area_value
    assert_equal "sqft", property.area_unit
    assert_equal tags(:one).id, property.cost_tag_id
  end

  test "create rejects an unknown accountable type" do
    assert_account_rejected({ name: "Bad", accountable_type: "Spaceship", balance: 1 })
  end

  test "create requires a name and a balance" do
    assert_account_rejected({ accountable_type: "Depository", balance: 1 })
    assert_account_rejected({ name: "No balance", accountable_type: "Depository" })
  end

  test "create rejects an invalid opening_balance_date" do
    assert_account_rejected({ name: "Bad date", accountable_type: "Depository", balance: 1, opening_balance_date: "not-a-date" })
  end

  test "create rejects balances that are not finite numbers in the stored range" do
    [ "1,250.50", "abc", "12abc", "Infinity", "NaN", "1e400", "1000000000000000" ].each do |balance|
      assert_account_rejected({ name: "Bad balance", accountable_type: "Depository", balance: balance }, "balance #{balance.inspect}")
    end
  end

  test "create rejects a malformed loan initial_balance" do
    assert_account_rejected(loan_params(initial_balance: "5,000"))
  end

  test "create rejects an unsupported currency before persisting anything" do
    assert_no_difference "Entry.count" do
      assert_account_rejected({ name: "Mystery money", accountable_type: "Depository", balance: 1, currency: "ZZZ" })
    end
  end

  test "create rejects a loan start_date that is not a real date" do
    [ "not-a-date", "2026-13-45", "2026-6-3", "20260603" ].each do |start_date|
      assert_account_rejected(loan_params(start_date: start_date), "start_date #{start_date.inspect}")
    end
  end

  test "create rejects a property cost tag from another family" do
    foreign_tag = families(:empty).tags.create!(name: "Not yours")

    assert_account_rejected({
      name: "Cottage", accountable_type: "Property", balance: "1", accountable_attributes: { cost_tag_id: foreign_tag.id }
    })
  end

  test "create answers a missing account with 400 and a non-object account with 422" do
    post "/api/v1/accounts", params: {}, headers: api_headers(write_api_key), as: :json
    assert_response :bad_request

    [ "foo", [ 1 ] ].each do |account|
      assert_no_difference "Account.count" do
        post "/api/v1/accounts", params: { account: account }, headers: api_headers(write_api_key), as: :json
      end
      assert_response :unprocessable_entity, "account #{account.inspect}"
    end
  end

  test "create rejects an invalid enum value in accountable_attributes" do
    assert_account_rejected({ name: "Coin", accountable_type: "Crypto", balance: 1, accountable_attributes: { tax_treatment: "bogus" } })
  end

  test "create ignores an accountable id instead of failing to find it" do
    supplied_id = SecureRandom.uuid
    post_account(loan_params(id: supplied_id, initial_balance: "40000"))

    assert_response :created
    assert_not_equal supplied_id, @user.family.accounts.find(JSON.parse(response.body)["id"]).accountable_id
  end

  test "create rejects numeric accountable_attributes that are not numbers" do
    {
      "interest_rate" => "abc",
      "term_months" => "12x",
      "down_payment" => "1,000"
    }.each do |field, value|
      assert_account_rejected(loan_params(field => value), "#{field}=#{value.inspect}")
    end

    assert_account_rejected({ name: "Cottage", accountable_type: "Property", balance: 1, accountable_attributes: { year_built: "abc" } })
  end

  test "create rejects a subtype the account type does not have" do
    assert_account_rejected({ name: "Odd", accountable_type: "Depository", balance: 1, subtype: "bogus" })

    post_account({ name: "Savings", accountable_type: "Depository", balance: 1, subtype: "savings" })
    assert_response :created
  end

  test "create rejects an opening_balance_date in the future" do
    assert_account_rejected({ name: "Future", accountable_type: "Depository", balance: 1, opening_balance_date: 1.day.from_now.to_date.iso8601 })
  end

  test "create reports a loan start_date in the future as a start_date problem" do
    assert_account_rejected(loan_params(start_date: 3.days.from_now.to_date.iso8601))
    assert_no_match(/opening date is today/, JSON.parse(response.body)["message"])
  end

  test "create reports model validation errors as 422" do
    assert_account_rejected(loan_params(start_date: 1.year.from_now.to_date.iso8601, initial_balance: nil))
  end

  private

    def write_api_key
      @write_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test Write Key",
        scopes: [ "read_write" ],
        source: "mobile",
        display_key: "test_write_#{SecureRandom.hex(8)}"
      )
    end

    def post_account(account, key: write_api_key)
      post "/api/v1/accounts", params: { account: account }, headers: api_headers(key)
    end

    def assert_account_rejected(account, message = nil)
      assert_no_difference "Account.count" do
        post_account(account)
      end

      assert_response :unprocessable_entity, message
      assert_equal "validation_failed", JSON.parse(response.body)["error"]
    end

    # A 36 month loan with a current balance below its original principal.
    def loan_params(balance: "40000", **loan_attributes)
      {
        name: "Loan",
        accountable_type: "Loan",
        balance: balance,
        accountable_attributes: { initial_balance: "50000", term_months: 36, interest_rate: 5, rate_type: "fixed" }.merge(loan_attributes)
      }
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def money_cents(money)
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i
    end

    def assert_nullable_equal(expected, actual)
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end
end
