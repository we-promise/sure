# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ApiRateLimiter.stubs(:limit).returns(nil) # the field matrix sends hundreds of requests
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
    assert property.user_set_area?, "an area typed in by the client must survive a later valuation refresh"
  end

  test "create rejects an unknown accountable type" do
    assert_account_rejected({ name: "Bad", accountable_type: "Spaceship", balance: 1 })
  end

  test "create requires a name and a balance" do
    assert_account_rejected({ accountable_type: "Depository", balance: 1 })
    assert_account_rejected({ name: "No balance", accountable_type: "Depository" })
  end

  test "create rejects balances that are not finite numbers in the stored range" do
    [ "1,250.50", "abc", "12abc", "Infinity", "NaN", "1e400", "1000000000000000" ].each do |balance|
      assert_account_rejected({ name: "Bad balance", accountable_type: "Depository", balance: balance }, "balance #{balance.inspect}")
    end
  end

  test "create rejects an unsupported currency before persisting anything" do
    assert_no_difference "Entry.count" do
      assert_account_rejected({ name: "Mystery money", accountable_type: "Depository", balance: 1, currency: "ZZZ" })
    end
  end

  test "create rejects a property cost tag from another family" do
    foreign_tag = families(:empty).tags.create!(name: "Not yours")

    assert_account_rejected({
      name: "Cottage", accountable_type: "Property", balance: "1", accountable_attributes: { cost_tag_id: foreign_tag.id }
    })
  end

  test "create answers a missing account with 400 and a wrong-typed account with 422" do
    post "/api/v1/accounts", params: {}, headers: api_headers(write_api_key), as: :json
    assert_response :bad_request

    [ "", {}, nil ].each do |account|
      post "/api/v1/accounts", params: { account: account }, headers: api_headers(write_api_key), as: :json
      assert_response :bad_request, "account #{account.inspect}"
    end

    [ "foo", [ 1 ], [] ].each do |account|
      assert_no_difference "Account.count" do
        post "/api/v1/accounts", params: { account: account }, headers: api_headers(write_api_key), as: :json
      end
      assert_response :unprocessable_entity, "account #{account.inspect}"
    end
  end

  test "create ignores an accountable id instead of failing to find it" do
    supplied_id = SecureRandom.uuid
    post_account(loan_params(id: supplied_id, initial_balance: "40000"))

    assert_response :created
    assert_not_equal supplied_id, @user.family.accounts.find(JSON.parse(response.body)["id"]).accountable_id
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

  # Values no column of that type can hold, one for each way a request goes
  # wrong: not a single value (an array, which `permit` would drop), a value of
  # another type (which ActiveRecord would convert) and text that is almost
  # right. They are sent as JSON for every field the endpoint reads, taken from
  # the controller's own lists, so a field added later is covered here too.
  WRONG_SHAPES = {
    string: [ [ "x" ], true, 12345 ],
    integer: [ [ 1 ], false, "12abc", 1.5, "1e1000000000" ],
    decimal: [ [ 1 ], false, "12abc", "NaN", 12345678901234.1234, "1e-1000000000", "1e1000000000", "1e-99999999999999999999" ],
    date: [ "2026-13-45", "2026-6-3", 20260603, [ "2026-01-01" ] ],
    boolean: [ "banana", 2, [ true ] ],
    uuid: [ [ "x" ], 5, "not-a-uuid" ]
  }.freeze

  test "create refuses wrong shaped values in every account field" do
    plain = plain_account("Depository")

    Api::V1::AccountsController::ACCOUNT_FIELDS.each do |field|
      assert_wrong_shapes_rejected(Account, field, field) { |bad| plain.merge(field => bad) }
    end
  end

  Accountable::TYPES.each do |type|
    fields = "#{type.pluralize}Controller".constantize.permitted_accountable_attributes.grep(Symbol) -
             Api::V1::AccountsController::UPDATE_ONLY_FIELDS
    next if fields.empty?

    test "create refuses wrong shaped values in every #{type} field" do
      plain = plain_account(type)

      fields.each do |field|
        assert_wrong_shapes_rejected(type.constantize, field, "#{type} #{field}") do |bad|
          plain.merge(accountable_attributes: plain[:accountable_attributes].merge(field => bad))
        end
      end
    end
  end

  test "create refuses an accountable_attributes or accountable_type that is not the right kind of value" do
    [ [ 1 ], [], "x", true ].each do |bad|
      assert_account_rejected(plain_account("Depository").merge(accountable_attributes: bad), bad.inspect, field: :accountable_attributes, as: :json)
    end
    [ [ "Loan" ], { "a" => 1 }, true, 5 ].each do |bad|
      assert_account_rejected(plain_account("Depository").merge(accountable_type: bad), bad.inspect, field: :accountable_type, as: :json)
    end
  end

  test "create takes a loan's rate_changes only as a list of objects with plain values" do
    loan = plain_account("Loan")
    loan[:accountable_attributes][:rate_type] = "variable"

    [ "oops", { "a" => 1 }, [ [ 1 ] ], [ "2025-06-01" ], [ { "effective_date" => [ "2025-06-01" ], "rate" => "6" } ] ].each do |bad|
      assert_account_rejected(loan.merge(accountable_attributes: loan[:accountable_attributes].merge(rate_changes: bad)), bad.inspect, field: :rate_changes, as: :json)
    end

    good = [ { "effective_date" => "2025-06-01", "rate" => "6.5" } ]
    post_account(loan.merge(accountable_attributes: loan[:accountable_attributes].merge(rate_changes: good)), as: :json)
    assert_response :created
  end

  test "create refuses values that the models only understand a few of" do
    { "Loan" => %i[rate_type insurance_rate_type day_count_convention], "Property" => %i[area_unit],
      "Vehicle" => %i[mileage_unit], "Crypto" => %i[tax_treatment] }.each do |type, fields|
      fields.each do |field|
        plain = plain_account(type)
        assert_no_difference "Account.count" do
          post_account(plain.merge(accountable_attributes: plain[:accountable_attributes].merge(field => "bogus")), as: :json)
        end
        assert_response :unprocessable_entity, "#{type} #{field}"
      end
    end
  end

  test "create checks the subtype sent on the account and the one sent inside accountable_attributes" do
    cottage = { name: "Cottage", accountable_type: "Property", balance: 1 }

    assert_account_rejected(cottage.merge(subtype: "single_family_home", accountable_attributes: { subtype: "bogus" }), "the second one would replace the first")
    assert_account_rejected(cottage.merge(subtype: "single_family_home", accountable_attributes: { subtype: "condominium" }), "two valid subtypes that disagree")
    assert_account_rejected({ name: "Car", accountable_type: "Vehicle", balance: 1, subtype: "sedan" }, "Vehicle has no subtypes")

    post_account(cottage.merge(subtype: "condominium", accountable_attributes: { subtype: "condominium" }))
    assert_response :created
    post_account(cottage.merge(accountable_attributes: { subtype: "townhouse" }))
    assert_response :created
  end

  test "create accepts JSON numbers, zero and booleans" do
    post_account({
      name: "Typed", accountable_type: "Loan", balance: 100.5, exclude_from_reports: true,
      accountable_attributes: { initial_balance: 100.5, term_months: 12, interest_rate: 0, rate_type: "fixed", principal_only_transfers: false }
    }, as: :json)

    assert_response :created
    account = @user.family.accounts.find(JSON.parse(response.body)["id"])
    assert_equal BigDecimal("100.5"), account.balance
    assert account.exclude_from_reports
    assert_equal 0, account.accountable.interest_rate
    assert_equal false, account.accountable.principal_only_transfers
  end

  test "create refuses numbers that Ruby would read differently from how they look" do
    [ "1_000", "1__0", "0x10", "1e", ".", "--1", "1 000" ].each do |balance|
      assert_account_rejected({ name: "Odd", accountable_type: "Depository", balance: balance }, "balance #{balance.inspect}", field: :balance)
    end
    assert_account_rejected(loan_params(term_months: "1_2"), field: :term_months)
  end

  test "create refuses a number with more decimal places than its column keeps instead of rounding it" do
    [ "1.123456789", 0.00001 ].each do |balance|
      assert_account_rejected({ name: "Odd", accountable_type: "Depository", balance: balance }, "balance #{balance.inspect}", field: :balance, as: :json)
    end
    assert_account_rejected(loan_params(interest_rate: "5.1234"), field: :interest_rate)
  end

  test "create accepts the usual ways to write a number or a flag" do
    post_account({
      name: "Forms", accountable_type: "Loan", balance: " 100.1234 ", exclude_from_reports: "True",
      accountable_attributes: { initial_balance: "100.1234", term_months: 12.0, interest_rate: "5.125", rate_type: "fixed", principal_only_transfers: 0 }
    }, as: :json)

    assert_response :created
    account = @user.family.accounts.find(JSON.parse(response.body)["id"])
    assert_equal BigDecimal("100.1234"), account.balance
    assert account.exclude_from_reports
    assert_equal 12, account.accountable.term_months
    assert_equal false, account.accountable.principal_only_transfers
  end

  test "create accepts the update-only vehicle fields when they are null or empty" do
    post_account({ name: "Car", accountable_type: "Vehicle", balance: 1, accountable_attributes: { purchase_date: nil, initial_balance_shown: "" } }, as: :json)

    assert_response :created
  end

  test "create refuses the vehicle fields that only mean something when updating" do
    %i[purchase_date initial_balance_shown].each do |field|
      assert_account_rejected(
        { name: "Car", accountable_type: "Vehicle", balance: 1, accountable_attributes: { field => "2020-01-01" } },
        field.to_s, field: field, as: :json
      )
    end
  end

  test "create checks every row of rate_changes" do
    loan = plain_account("Loan")
    loan[:accountable_attributes][:rate_type] = "variable"
    rows = [
      [ { "effective_date" => "2025-06-01", "rate" => "6", "pct" => "1" } ],
      [ { "date" => "2025-06-01", "pct" => "6" } ],
      [ { "effective_date" => "", "rate" => "" } ],
      [ { "effective_date" => 20250601, "rate" => 6 } ],
      [ { "effective_date" => "20250601", "rate" => 6 } ],
      [ { "effective_date" => "2025-06-01", "rate" => "6_0" } ],
      [ { "effective_date" => "2025-06-01", "rate" => "1e-1000000000" } ],
      [ { "effective_date" => "2025-06-01", "rate" => "1e-99999999999999999999" } ],
      [ { "effective_date" => "2025-06-01", "rate" => "6" }, { "effective_date" => "2025-06-01", "rate" => "7" } ]
    ]

    rows.each do |bad|
      assert_account_rejected(loan.merge(accountable_attributes: loan[:accountable_attributes].merge(rate_changes: bad)), bad.inspect, field: :rate_changes, as: :json)
    end
  end

  test "create refuses rate_changes on a loan that does not have a variable rate" do
    loan = plain_account("Loan")
    loan[:accountable_attributes][:rate_changes] = [ { "effective_date" => "2025-06-01", "rate" => "6" } ]

    assert_account_rejected(loan, field: :rate_changes, as: :json)
  end

  test "create answers 201 for an account that is committed even when scheduling its first sync fails" do
    Account.any_instance.stubs(:sync_later).raises(StandardError, "queue is down")

    assert_difference "Account.count", 1 do
      post_account({ name: "Queue down", accountable_type: "Depository", balance: 10 })
    end

    assert_response :created
    assert DebugLogEntry.exists?(category: "api", level: "error"), "the failure should leave a trace"
  end

  test "create accepts the numbers the format allows, exponents and leading dots included" do
    { "1.5e3" => 1500, ".5" => 0.5, "+7" => 7, "0" => 0, "-3.25" => -3.25 }.each do |written, expected|
      post_account({ name: "Number #{written}", accountable_type: "Depository", balance: written }, as: :json)

      assert_response :created, "balance #{written.inspect}"
      assert_equal BigDecimal(expected.to_s), @user.family.accounts.find(JSON.parse(response.body)["id"]).balance
    end
  end

  test "create refuses a trailing dot and a list of more than 1000 rate_changes rows" do
    assert_account_rejected({ name: "Dot", accountable_type: "Depository", balance: "100." }, field: :balance, as: :json)

    loan = plain_account("Loan")
    loan[:accountable_attributes].merge!(rate_type: "variable", rate_changes: Array.new(1001) { { "effective_date" => "2025-06-01", "rate" => "5" } })
    assert_account_rejected(loan, field: :rate_changes, as: :json)
  end

  test "create accepts a rate_changes rate with more than three decimals" do
    loan = plain_account("Loan")
    loan[:accountable_attributes].merge!(rate_type: "variable", rate_changes: [ { "effective_date" => "2025-06-01", "rate" => "4.1255" } ])

    post_account(loan, as: :json)

    assert_response :created
  end

  test "create treats an empty string for a whole object or list as not sent" do
    post_account({ name: "Empty", accountable_type: "Depository", balance: 1, accountable_attributes: "" }, as: :json)
    assert_response :created

    loan = plain_account("Loan")
    loan[:accountable_attributes].merge!(rate_type: "variable", rate_changes: "")
    post_account(loan, as: :json)
    assert_response :created
  end

  test "create locks a subtype that was sent on the account as well as one inside accountable_attributes" do
    post_account({ name: "Condo", accountable_type: "Property", balance: 1, subtype: "condominium" })

    assert_response :created
    assert @user.family.accounts.find(JSON.parse(response.body)["id"]).accountable.locked?(:subtype)
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

    def post_account(account, key: write_api_key, **options)
      post "/api/v1/accounts", params: { account: account }, headers: api_headers(key), **options
    end

    # The smallest valid request for an account type.
    def plain_account(type)
      return loan_params if type == "Loan"

      { name: "Plain #{type}", accountable_type: type, balance: "100", accountable_attributes: {} }
    end

    def wrong_shape_kind(model, field)
      type = Api::V1::AccountsController::FIELD_TYPES.fetch(field) { model.type_for_attribute(field.to_s) }.type
      { text: :string, float: :decimal, nil => :string }.fetch(type, type)
    end

    # Pass field: to also check that the error names it.
    def assert_account_rejected(account, message = nil, field: nil, **options)
      assert_no_difference "Account.count" do
        post_account(account, **options)
      end

      assert_response :unprocessable_entity, message
      assert_equal "validation_failed", JSON.parse(response.body)["error"]
      assert_includes JSON.parse(response.body)["message"], field.to_s, message if field
    end

    def assert_wrong_shapes_rejected(model, field, label)
      WRONG_SHAPES.fetch(wrong_shape_kind(model, field)).each do |bad|
        assert_account_rejected(yield(bad), "#{label}=#{bad.inspect}", field: field, as: :json)
      end
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
