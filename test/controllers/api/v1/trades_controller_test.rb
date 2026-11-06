# frozen_string_literal: true

require "test_helper"

class Api::V1::TradesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @investment_account = accounts(:investment)
    @read_write_api_key = nil
    @read_only_api_key = nil
  end

  test "create dividend with security returns 201" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        amount: 25.50,
        currency: "USD",
        ticker: "AAPL|XNAS"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Dividend: AAPL", body["name"]
    assert_equal "Dividend", body["investment_activity_label"]
    assert_equal 0, body["qty"].to_i
  end

  test "create dividend without security returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        amount: 25.50
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create dividend without amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        ticker: "AAPL|XNAS"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create buy trade returns 201" do
    security = Security.create!(ticker: "TEST", name: "Test Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 10,
        price: 100.00,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Buy", body["investment_activity_label"]
  end

  test "create sell trade returns 201" do
    security = Security.create!(ticker: "TEST", name: "Test Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "sell",
        date: Date.current,
        qty: 10,
        price: 100.00,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Sell", body["investment_activity_label"]
  end

  test "create sweep in trade returns 201" do
    security = Security.create!(ticker: "SWIN", name: "Sweep In Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "sweep_in",
        date: Date.current,
        qty: 10,
        price: 1.00,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Sweep In", body["investment_activity_label"]
    assert_equal 10, body["qty"].to_i
  end

  test "create sweep out trade returns 201" do
    security = Security.create!(ticker: "SWOUT", name: "Sweep Out Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "sweep_out",
        date: Date.current,
        qty: 10,
        price: 1.00,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Sweep Out", body["investment_activity_label"]
    assert_equal(-10, body["qty"].to_i)
  end

  test "create reinvestment trade returns 201" do
    security = Security.create!(ticker: "REINV", name: "Reinvestment Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "reinvestment",
        date: Date.current,
        qty: 2,
        price: 12.34,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Reinvestment", body["investment_activity_label"]
    assert_equal 2, body["qty"].to_i
  end

  test "create fee trade returns 201" do
    security = Security.create!(ticker: "FEESEC", name: "Fee Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "fee",
        date: Date.current,
        amount: 0.68,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Fee", body["investment_activity_label"]
    assert_equal 0, body["qty"].to_d
    assert_in_delta 0.68, Trade.find(body["id"]).entry.amount.to_f, 0.001
  end

  test "invalid type returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "invalid",
        date: Date.current
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "rejects a type-label mismatch without persisting a trade" do
    security = Security.create!(ticker: "MISMATCH", name: "Mismatch Security", country_code: "US")

    assert_no_difference [ "Entry.count", "Trade.count" ] do
      post "/api/v1/trades",
        params: { trade: {
          account_id: @investment_account.id,
          type: "sweep_out",
          investment_activity_label: "Buy",
          date: Date.current,
          qty: 10,
          price: 1,
          security_id: security.id
        } },
        headers: api_headers(read_write_api_key)
    end

    assert_response :unprocessable_entity
  end

  # Trades have no category column, so a category_id is not a trade field: it
  # is ignored like any other unpermitted parameter, whoever owns the category.
  test "create ignores a category_id and saves the trade" do
    security = Security.create!(ticker: "CATBUY", name: "Category Buy Security", country_code: "US")

    category_ids_from_every_source.each do |source, category_id|
      assert_difference [ "Entry.count", "Trade.count" ], 1, "#{source} category" do
        post "/api/v1/trades",
          params: { trade: {
            account_id: @investment_account.id,
            type: "buy",
            date: Date.current,
            qty: 10,
            price: 3,
            security_id: security.id,
            category_id: category_id
          } },
          headers: api_headers(read_write_api_key)
      end

      assert_response :created, "#{source} category"
      body = JSON.parse(response.body)
      trade = Trade.find(body["id"])
      assert_equal 10, trade.qty, "#{source} category"
      assert_equal 3, trade.price, "#{source} category"
      assert body.key?("category"), "#{source} category"
      assert_nil body["category"], "#{source} category"
    end
  end

  test "update ignores a category_id and saves the other fields" do
    trade_id = create_buy_trade("CATUPD")

    category_ids_from_every_source.each do |source, category_id|
      put api_v1_trade_url(trade_id),
        params: { trade: { notes: "Notes with #{source} category", category_id: category_id } },
        headers: api_headers(read_write_api_key)

      assert_response :ok, "#{source} category"
      body = JSON.parse(response.body)
      assert_equal "Notes with #{source} category", body["notes"]
      assert_equal "Notes with #{source} category", Trade.find(trade_id).entry.notes
      assert_nil body["category"], "#{source} category"
    end
  end

  test "an update carrying only a category_id changes nothing" do
    trade = Trade.find(create_buy_trade("CATNOOP"))
    reset_update_side_effects(trade)
    entry_before = trade.entry.reload.attributes
    trade_before = trade.reload.attributes

    assert_no_enqueued_jobs only: SyncJob do
      put api_v1_trade_url(trade),
        params: { trade: { category_id: categories(:food_and_drink).id } },
        headers: api_headers(read_write_api_key)
    end

    assert_response :ok
    assert_equal entry_before, trade.entry.reload.attributes
    assert_equal trade_before, trade.reload.attributes
    assert_not trade.entry.user_modified?
    assert_empty trade.entry.locked_attributes
    assert_empty trade.locked_attributes
  end

  # One change saves only the entry, the other only the trade, so each half of
  # the changed-anything check is exercised on its own.
  test "an update that changes a field marks, locks and syncs the trade" do
    {
      "entry" => [ { notes: "Changed notes" }, :entry, "notes" ],
      "trade" => [ { investment_activity_label: "Other" }, :trade, "investment_activity_label" ]
    }.each do |source, (fields, locked_on, locked_attr)|
      trade = Trade.find(create_buy_trade("CAT#{source.upcase}"))
      reset_update_side_effects(trade)

      assert_enqueued_with(job: SyncJob) do
        put api_v1_trade_url(trade),
          params: { trade: fields.merge(category_id: categories(:food_and_drink).id) },
          headers: api_headers(read_write_api_key)
      end

      assert_response :ok, "#{source} change"
      trade.reload
      assert trade.entry.reload.user_modified?, "#{source} change"
      locked = locked_on == :entry ? trade.entry.locked_attributes : trade.locked_attributes
      assert_includes locked.keys, locked_attr, "#{source} change"
    end
  end

  test "create deposit returns 201" do
     post "/api/v1/trades",
       params: { trade: {
         account_id: @investment_account.id,
         type: "deposit",
         date: Date.current,
         amount: 175.25,
         currency: "USD"
       } },
       headers: api_headers(read_write_api_key)

     assert_response :created
     body = JSON.parse(response.body)
     assert body["id"].present?
     assert_match(/Deposit to/, body["name"])
   end

  test "create withdrawal returns 201" do
     post "/api/v1/trades",
       params: { trade: {
         account_id: @investment_account.id,
         type: "withdrawal",
         date: Date.current,
         amount: 100.00,
         currency: "USD"
       } },
       headers: api_headers(read_write_api_key)

     assert_response :created
     body = JSON.parse(response.body)
     assert body["id"].present?
     assert_match(/Withdrawal/, body["name"])
   end

  test "create withdrawal without amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "withdrawal",
        date: Date.current
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create withdrawal with transfer_account_id creates linked transfer" do
    depository = accounts(:depository)

    assert_difference "Transfer.count", 1 do
      post "/api/v1/trades",
        params: { trade: {
          account_id: @investment_account.id,
          type: "withdrawal",
          date: Date.current,
          amount: 500.00,
          currency: "USD",
          transfer_account_id: depository.id
        } },
        headers: api_headers(read_write_api_key)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert body["outflow_transaction"]["account"]["id"].present?
    assert body["outflow_transaction"]["account"]["account_type"].present?

    transfer = Transfer.joins(outflow_transaction: :entry)
                       .where(entries: { account_id: @investment_account.id })
                       .last

    assert transfer, "Transfer should exist linking accounts"
    assert_equal depository.id, transfer.inflow_transaction.entry.account_id, "Inflow should be to depository"
    assert_equal @investment_account.id, transfer.outflow_transaction.entry.account_id, "Outflow should come from investment"
  end

  # The transfer books an entry on the other account too, so the key's user
  # needs write permission there. family_member can write to the investment
  # account here, only read credit_card and not see connected at all.
  test "create withdrawal rejects a transfer account the user may only read or not access" do
    @user = users(:family_member)
    @investment_account.account_shares.create!(user: @user, permission: "full_control")

    [ accounts(:credit_card), accounts(:connected) ].each do |transfer_account|
      assert_no_difference [ "Entry.count", "Transfer.count" ] do
        post "/api/v1/trades",
          params: { trade: {
            account_id: @investment_account.id,
            type: "withdrawal",
            date: Date.current,
            amount: 500.00,
            currency: "USD",
            transfer_account_id: transfer_account.id
          } },
          headers: api_headers(read_write_api_key)
      end

      assert_response :not_found
      assert_equal "Account not found", JSON.parse(response.body)["message"]
    end
  end

  test "create deposit without amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "deposit",
        date: Date.current
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create deposit with transfer_account_id creates linked transfer" do
    depository = accounts(:depository)

    assert_difference "Transfer.count", 1 do
      post "/api/v1/trades",
        params: { trade: {
          account_id: @investment_account.id,
          type: "deposit",
          date: Date.current,
          amount: 500.00,
          currency: "USD",
          transfer_account_id: depository.id
        } },
        headers: api_headers(read_write_api_key)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert body["inflow_transaction"]["account"]["id"].present?
    assert body["inflow_transaction"]["account"]["account_type"].present?

    transfer = Transfer.joins(inflow_transaction: :entry)
                       .where(entries: { account_id: @investment_account.id })
                       .last

    assert transfer, "Transfer should exist linking accounts"
    assert_equal depository.id, transfer.outflow_transaction.entry.account_id, "Outflow should be from depository"
    assert_equal @investment_account.id, transfer.inflow_transaction.entry.account_id, "Inflow should go to investment"
  end

  test "create interest returns 201" do
       post "/api/v1/trades",
         params: { trade: {
           account_id: @investment_account.id,
           type: "interest",
           date: Date.current,
           amount: 25.00,
           currency: "USD"
         } },
         headers: api_headers(read_write_api_key)

       assert_response :created
       body = JSON.parse(response.body)
       assert body["id"].present?
       assert_equal "Interest", body["investment_activity_label"]
     end

  test "create interest with explicit ticker returns 201" do
    security = Security.create!(ticker: "INTSEC", name: "Interest Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "interest",
        date: Date.current,
        amount: 25.00,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :created
    body = JSON.parse(response.body)
    assert body["id"].present?
    assert_equal "Interest", body["investment_activity_label"]
  end

  test "create interest without amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "interest",
        date: Date.current
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "create requires read_write scope" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 10,
        price: 100
      } },
      headers: api_headers(read_only_api_key)

    assert_response :forbidden
  end

  test "should reject create without API key" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 10,
        price: 100
      } }

    assert_response :unauthorized
  end

  test "should return 404 for unknown account_id" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: 999999,
        type: "buy",
        date: Date.current,
        qty: 10,
        price: 100,
        security_id: Security.create!(ticker: "TEST", name: "Test", country_code: "US").id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :not_found
  end

  test "should return 422 for invalid date format" do
    security = Security.create!(ticker: "INVDATE", name: "Invalid Date Security", country_code: "US")

    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: "invalid-date",
        qty: 10,
        price: 100,
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["errors"].any? { |e| e.downcase.include?("date") }, "Expected date-related error, got: #{body["errors"].inspect}"
  end

  # INDEX action tests
  test "should get index with valid API key" do
    get api_v1_trades_url, headers: api_headers(read_write_api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data.key?("trades")
    assert response_data.key?("pagination")
    assert response_data["pagination"].key?("page")
    assert response_data["pagination"].key?("per_page")
    assert response_data["pagination"].key?("total_count")
    assert response_data["pagination"].key?("total_pages")
  end

  test "should get index with read-only API key" do
    get api_v1_trades_url, headers: api_headers(read_only_api_key)
    assert_response :success
  end

  test "should filter trades by account_id" do
    get api_v1_trades_url,
      params: { account_id: @investment_account.id },
      headers: api_headers(read_write_api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    response_data["trades"].each do |trade|
      assert_equal @investment_account.id, trade["account"]["id"]
    end
  end

  test "should filter trades by date range" do
    start_date = 1.year.ago.to_date
    end_date = Date.current

    get api_v1_trades_url,
      params: { start_date: start_date, end_date: end_date },
      headers: api_headers(read_write_api_key)
    assert_response :success
  end

  test "should reject index request without API key" do
    get api_v1_trades_url
    assert_response :unauthorized
  end

  test "should reject index request with invalid API key" do
    get api_v1_trades_url, headers: { "X-Api-Key" => "invalid-key" }
    assert_response :unauthorized
  end

  test "should reject index request with invalid date format" do
    get api_v1_trades_url,
      params: { start_date: "invalid" },
      headers: api_headers(read_write_api_key)
    assert_response :unprocessable_entity
  end

  # SHOW action tests
  test "should show trade with valid API key" do
    security = Security.create!(ticker: "SHOW", name: "Show Security", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    get api_v1_trade_url(trade_id), headers: api_headers(read_write_api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal trade_id, response_data["id"]
    assert response_data.key?("date")
    assert response_data.key?("account")
  end

  test "should show trade with read-only API key" do
    security = Security.create!(ticker: "SHOR", name: "Show RO Security", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    get api_v1_trade_url(trade_id), headers: api_headers(read_only_api_key)
    assert_response :success
  end

  test "should return 404 for non-existent trade" do
    get api_v1_trade_url(999999), headers: api_headers(read_write_api_key)
    assert_response :not_found
  end

  test "should reject show request without API key" do
    security = Security.create!(ticker: "SHON", name: "Show No Auth", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    get api_v1_trade_url(trade_id)
    assert_response :unauthorized
  end

  # UPDATE action tests
  test "should update trade with valid parameters" do
    security = Security.create!(ticker: "UPD", name: "Update Security", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    update_params = {
      trade: {
        notes: "Updated notes"
      }
    }

    put api_v1_trade_url(trade_id),
      params: update_params,
      headers: api_headers(read_write_api_key)
    assert_response :ok

    response_data = JSON.parse(response.body)
    assert_equal "Updated notes", response_data["notes"]
  end

  test "updates a security trade to sweep out with matching sign and label" do
    security = Security.create!(ticker: "UPDSWEEP", name: "Update Sweep Security", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    trade_id = JSON.parse(response.body).fetch("id")

    patch api_v1_trade_url(trade_id),
      params: { trade: { type: "sweep_out", qty: 4 } },
      headers: api_headers(read_write_api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal(-4, body["qty"].to_d)
    assert_equal "Sweep Out", body["investment_activity_label"]
  end

  test "rejects unsupported cash trade types on update" do
    trade = @investment_account.trades.first

    patch api_v1_trade_url(trade.id),
      params: { trade: { type: "fee", qty: 1 } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "should reject update with read-only API key" do
    security = Security.create!(ticker: "UPDRO", name: "Update RO Security", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    put api_v1_trade_url(trade_id),
      params: { trade: { notes: "Test" } },
      headers: api_headers(read_only_api_key)
    assert_response :forbidden
  end

  test "should reject update for non-existent trade" do
    put api_v1_trade_url(999999),
      params: { trade: { notes: "Test" } },
      headers: api_headers(read_write_api_key)
    assert_response :not_found
  end

  test "should reject update without API key" do
    security = Security.create!(ticker: "UPDNO", name: "Update No Auth", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    put api_v1_trade_url(trade_id), params: { trade: { notes: "Test" } }
    assert_response :unauthorized
  end

  test "should reject update with invalid date format" do
     security = Security.create!(ticker: "UPDID", name: "Update Invalid Date", country_code: "US")
     post "/api/v1/trades",
       params: { trade: {
         account_id: @investment_account.id,
         type: "buy",
         date: Date.current,
         qty: 5,
         price: 100,
         currency: "USD",
         security_id: security.id
       } },
       headers: api_headers(read_write_api_key)
     assert_response :created
     trade_id = JSON.parse(response.body)["id"]

     put api_v1_trade_url(trade_id),
            params: { trade: { date: "invalid" } },
            headers: api_headers(read_write_api_key)
     assert_response :unprocessable_entity
   end

  test "should update dividend trade with valid parameters" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        amount: 25.50,
        currency: "USD",
        ticker: "AAPL|XNAS"
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    update_params = {
      trade: {
        notes: "Updated dividend notes"
      }
    }

    put api_v1_trade_url(trade_id),
      params: update_params,
      headers: api_headers(read_write_api_key)
    assert_response :ok

    response_data = JSON.parse(response.body)
    assert_equal "Updated dividend notes", response_data["notes"]
  end

  # DESTROY action tests
  test "should destroy trade" do
    security = Security.create!(ticker: "DEL", name: "Delete Security", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    delete api_v1_trade_url(trade_id), headers: api_headers(read_write_api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data.key?("message")
  end

  test "should reject destroy with read-only API key" do
    security = Security.create!(ticker: "DELRO", name: "Delete RO Security", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    delete api_v1_trade_url(trade_id), headers: api_headers(read_only_api_key)
    assert_response :forbidden
  end

  test "should reject destroy for non-existent trade" do
    delete api_v1_trade_url(999999), headers: api_headers(read_write_api_key)
    assert_response :not_found
  end

  test "should reject destroy without API key" do
    security = Security.create!(ticker: "DELNO", name: "Delete No Auth", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    delete api_v1_trade_url(trade_id)
    assert_response :unauthorized
  end

  # Non-numeric amount returns 422
  test "create deposit with non-numeric amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "deposit",
        date: Date.current,
        amount: "abc",
        currency: "USD"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Amount must be a valid number", body["message"]
  end

  test "create deposit with zero amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "deposit",
        date: Date.current,
        amount: 0,
        currency: "USD"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Amount must be a valid number", body["message"]
  end

  test "create deposit with negative amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "deposit",
        date: Date.current,
        amount: -50.00,
        currency: "USD"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Amount must be a valid number", body["message"]
  end

  test "create interest with non-numeric amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "interest",
        date: Date.current,
        amount: "abc",
        currency: "USD"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Amount must be a valid number", body["message"]
  end

  test "create interest with zero amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "interest",
        date: Date.current,
        amount: 0,
        currency: "USD"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Amount must be a valid number", body["message"]
  end

  test "create dividend with non-numeric amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        amount: "abc",
        currency: "USD",
        ticker: "AAPL|XNAS"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Amount must be a valid number", body["message"]
  end

  test "create dividend with zero amount returns 422" do
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "dividend",
        date: Date.current,
        amount: 0,
        currency: "USD",
        ticker: "AAPL|XNAS"
      } },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Amount must be a valid number", body["message"]
  end

  test "trade JSON should have expected structure" do
    security = Security.create!(ticker: "JSP", name: "JSON Structure Security", country_code: "US")
    post "/api/v1/trades",
      params: { trade: {
        account_id: @investment_account.id,
        type: "buy",
        date: Date.current,
        qty: 5,
        price: 100,
        currency: "USD",
        security_id: security.id
      } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade_id = JSON.parse(response.body)["id"]

    get api_v1_trade_url(trade_id), headers: api_headers(read_write_api_key)
    assert_response :success

    trade_data = JSON.parse(response.body)
    assert trade_data.key?("id")
    assert trade_data.key?("date")
    assert trade_data.key?("account")
    assert trade_data["account"].key?("id")
    assert trade_data["account"].key?("name")
    assert trade_data["account"].key?("account_type")
    assert trade_data.key?("notes")
  end

  private

    def category_ids_from_every_source
      {
        "own" => categories(:food_and_drink).id,
        "foreign" => families(:empty).categories.create!(name: "Other family category", color: "#123456", lucide_icon: "circle").id,
        "unknown" => SecureRandom.uuid
      }
    end

    def create_buy_trade(ticker)
      security = Security.create!(ticker: ticker, name: "#{ticker} Security", country_code: "US")
      post "/api/v1/trades",
        params: { trade: {
          account_id: @investment_account.id,
          type: "buy",
          date: Date.current,
          qty: 5,
          price: 100,
          currency: "USD",
          security_id: security.id
        } },
        headers: api_headers(read_write_api_key)
      assert_response :created
      JSON.parse(response.body)["id"]
    end

    # Creating through the API marks, locks and syncs the trade, so clear that
    # state before measuring what an update does.
    def reset_update_side_effects(trade)
      trade.entry.update_columns(user_modified: false, locked_attributes: {})
      trade.update_columns(locked_attributes: {})
      trade.entry.account.syncs.delete_all
    end

    def read_write_api_key
      @read_write_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test RW Key",
        key: ApiKey.generate_secure_key,
        scopes: %w[read_write],
        source: "web"
      ).tap do |key|
        Redis.new.del("api_rate_limit:#{key.id}")
      end
    end

    def read_only_api_key
      @read_only_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test RO Key",
        key: ApiKey.generate_secure_key,
        scopes: %w[read],
        source: "mobile"
      ).tap do |key|
        Redis.new.del("api_rate_limit:#{key.id}")
      end
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
