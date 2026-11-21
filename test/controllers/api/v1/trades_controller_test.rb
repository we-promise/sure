# frozen_string_literal: true

require "test_helper"

class Api::V1::TradesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

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

  # The update and its follow-up writes are one change: if marking fails, the
  # edit rolls back too, so a retry finds the change still to make and marks,
  # locks and syncs it then.
  test "an update whose follow-up write fails changes nothing, and a retry completes it" do
    trade = Trade.find(create_buy_trade("CATROLL"))
    reset_update_side_effects(trade)
    trade.entry.update_columns(notes: "Original notes")
    original_notes = trade.entry.reload.notes

    Entry.any_instance.stubs(:mark_user_modified!).raises(ActiveRecord::StatementInvalid, "write failed")
    put api_v1_trade_url(trade), params: { trade: { notes: "Retried notes" } }, headers: api_headers(read_write_api_key)
    assert_response :internal_server_error
    assert_equal original_notes, trade.entry.reload.notes, "the edit was kept without its follow-ups"
    Entry.any_instance.unstub(:mark_user_modified!)

    assert_enqueued_with(job: SyncJob) do
      put api_v1_trade_url(trade), params: { trade: { notes: "Retried notes" } }, headers: api_headers(read_write_api_key)
    end
    assert_response :ok
    assert_equal "Retried notes", trade.entry.reload.notes
    assert trade.entry.user_modified?
    assert_includes trade.entry.locked_attributes.keys, "notes"
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

  test "an update with only a type turns a buy into a sell, fee included" do
    trade = Trade.find(create_buy_trade("UPDTYPE", fee: 2))

    patch api_v1_trade_url(trade.id), params: { trade: { type: "sell" } }, headers: api_headers(read_write_api_key)

    assert_response :ok
    trade.reload
    assert_equal(-5, trade.qty)
    assert_equal 100, trade.price
    assert_equal(-498, trade.entry.amount)
    assert_equal "Sell", trade.investment_activity_label
    assert_equal Trade.build_name("sell", 5, "UPDTYPE"), trade.entry.name
  end

  test "an update with only a nature sets the side of the trade" do
    trade = Trade.find(create_buy_trade("UPDNAT"))

    patch api_v1_trade_url(trade.id), params: { trade: { nature: "inflow" } }, headers: api_headers(read_write_api_key)

    assert_response :ok
    trade.reload
    assert_equal(-5, trade.qty)
    assert_equal(-500, trade.entry.amount)
    assert_equal "Sell", trade.investment_activity_label

    patch api_v1_trade_url(trade.id), params: { trade: { nature: "outflow" } }, headers: api_headers(read_write_api_key)

    assert_response :ok
    trade.reload
    assert_equal 5, trade.qty
    assert_equal 500, trade.entry.amount
    assert_equal "Buy", trade.investment_activity_label
  end

  test "an update refuses a nature other than inflow or outflow" do
    trade = Trade.find(create_buy_trade("UPDBADNAT"))

    [ "inlfow", "income" ].each do |nature|
      patch api_v1_trade_url(trade.id), params: { trade: { nature: nature } }, headers: api_headers(read_write_api_key)

      assert_response :unprocessable_entity, nature
      trade.reload
      assert_equal 5, trade.qty, nature
      assert_equal "Buy", trade.investment_activity_label, nature
    end
  end

  test "an update refuses a qty or price sent blank" do
    trade = Trade.find(create_buy_trade("UPDBLANK"))

    [ { qty: "", price: "120" }, { qty: "" }, { price: nil } ].each do |change|
      patch api_v1_trade_url(trade.id), params: { trade: change }, headers: api_headers(read_write_api_key), as: :json

      assert_response :unprocessable_entity, change.inspect
      trade.reload
      assert_equal 5, trade.qty, change.inspect
      assert_equal 100, trade.price, change.inspect
    end
  end

  test "an update with only a price stores the price and recomputes the amount" do
    trade = Trade.find(create_buy_trade("UPDPRICE", fee: 2))

    patch api_v1_trade_url(trade.id), params: { trade: { price: "120.5" } }, headers: api_headers(read_write_api_key)

    assert_response :ok
    trade.reload
    assert_equal 5, trade.qty
    assert_equal BigDecimal("120.5"), trade.price
    assert_equal BigDecimal("604.5"), trade.entry.amount
  end

  test "an update with a qty and a price stores both" do
    trade = Trade.find(create_buy_trade("UPDBOTH"))

    patch api_v1_trade_url(trade.id), params: { trade: { qty: 3, price: 90 } }, headers: api_headers(read_write_api_key)

    assert_response :ok
    trade.reload
    assert_equal 3, trade.qty
    assert_equal 90, trade.price
    assert_equal 270, trade.entry.amount
  end

  test "an update with a qty or price that is not a positive number is refused and changes nothing" do
    trade = Trade.find(create_buy_trade("UPDBAD"))

    [
      [ { qty: "abc" }, "Quantity and price must be valid numbers" ],
      [ { price: "abc" }, "Quantity and price must be valid numbers" ],
      [ { qty: "2", price: "1e" }, "Quantity and price must be valid numbers" ],
      [ { qty: "0" }, "Quantity and price are required" ],
      [ { price: "-3" }, "Quantity and price are required" ]
    ].each do |attrs, message|
      patch api_v1_trade_url(trade.id), params: { trade: attrs }, headers: api_headers(read_write_api_key)

      assert_response :unprocessable_entity, attrs.inspect
      assert_equal message, JSON.parse(response.body)["message"], attrs.inspect
      trade.reload
      assert_equal 5, trade.qty
      assert_equal 100, trade.price
      assert_equal 500, trade.entry.amount
    end
  end

  test "a dividend cannot become a buy without a qty and a price" do
    post "/api/v1/trades",
      params: { trade: { account_id: @investment_account.id, type: "dividend", date: Date.current,
                         amount: 25.50, currency: "USD", ticker: "AAPL|XNAS" } },
      headers: api_headers(read_write_api_key)
    assert_response :created
    trade = Trade.find(JSON.parse(response.body)["id"])

    patch api_v1_trade_url(trade.id), params: { trade: { type: "buy" } }, headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    trade.reload
    assert_equal "Dividend", trade.investment_activity_label
    assert_equal BigDecimal("-25.5"), trade.entry.amount
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

  test "create refuses an amount, qty or price with trailing garbage instead of reading its leading digits" do
    security = Security.create!(ticker: "GARBAGE", name: "Garbage Security", country_code: "US")
    [
      [ { type: "deposit", amount: "12abc" }, "Amount must be a valid number" ],
      [ { type: "buy", qty: "5abc", price: 100, security_id: security.id }, "Quantity and price must be valid numbers" ],
      [ { type: "buy", qty: 5, price: "Infinity", security_id: security.id }, "Quantity and price must be valid numbers" ]
    ].each do |attrs, message|
      assert_no_difference "Entry.count" do
        post "/api/v1/trades",
          params: { trade: { account_id: @investment_account.id, date: Date.current, currency: "USD" }.merge(attrs) },
          headers: api_headers(read_write_api_key)
      end

      assert_response :unprocessable_entity, attrs.inspect
      assert_equal message, JSON.parse(response.body)["message"], attrs.inspect
    end
  end

  test "create refuses a fee that is not a non-negative number instead of storing it as zero" do
    security = Security.create!(ticker: "BADFEE", name: "Bad Fee Security", country_code: "US")
    [ "abc", "12abc", "Infinity", "-1" ].each do |fee|
      assert_no_difference "Entry.count" do
        post "/api/v1/trades",
          params: { trade: { account_id: @investment_account.id, type: "buy", date: Date.current, currency: "USD",
                             qty: 5, price: 100, fee: fee, security_id: security.id } },
          headers: api_headers(read_write_api_key)
      end

      assert_response :unprocessable_entity, fee
      body = JSON.parse(response.body)
      assert_equal "Fee must be a valid number", body["message"], fee
      assert_equal [ "fee must be a valid non-negative number" ], body["errors"], fee
    end
  end

  test "create stores a numeric fee and treats a blank one as zero" do
    assert_equal 2, Trade.find(create_buy_trade("GOODFEE", fee: "2")).fee
    assert_equal 0, Trade.find(create_buy_trade("BLANKFEE", fee: "")).fee
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

  test "show exposes the fee and the exchange rate stored on the trade" do
    security = Security.create!(ticker: "TAXF", name: "Tax Fields Security", country_code: "US")
    entry = @investment_account.entries.create!(
      date: Date.current,
      amount: 1001.25,
      name: "Buy TAXF",
      currency: "EUR",
      entryable: Trade.new(
        security: security,
        qty: 10,
        price: 100,
        fee: 1.2534,
        currency: "EUR",
        investment_activity_label: "Buy",
        extra: { "exchange_rate" => 0.9123, "provider_raw" => { "account_number" => "U1234567" } }
      )
    )

    get api_v1_trade_url(entry.entryable), headers: api_headers(read_only_api_key)
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal "1.2534", body["fee_decimal"]
    assert_equal Money.new(BigDecimal("1.2534"), "EUR").format, body["fee"]
    assert_equal 0.9123, body["exchange_rate"]
    assert_not body.key?("extra")
    assert_not_includes response.body, "U1234567"
  end

  test "index returns a zero fee and a null exchange rate when the trade has none" do
    security = Security.create!(ticker: "TAXN", name: "No Rate Security", country_code: "US")
    entry = @investment_account.entries.create!(
      date: Date.current,
      amount: 500,
      name: "Buy TAXN",
      currency: "USD",
      entryable: Trade.new(security: security, qty: 5, price: 100, currency: "USD", investment_activity_label: "Buy")
    )

    get api_v1_trades_url, params: { account_id: @investment_account.id, per_page: 100 }, headers: api_headers(read_only_api_key)
    assert_response :success

    trade_json = JSON.parse(response.body)["trades"].find { |trade| trade["id"] == entry.entryable.id }
    assert trade_json
    assert_equal "0.0", trade_json["fee_decimal"]
    assert trade_json.key?("exchange_rate")
    assert_nil trade_json["exchange_rate"]
  end

  test "show and index return a null exchange rate instead of failing when extra is not a hash" do
    security = Security.create!(ticker: "TAXX", name: "Malformed Extra Security", country_code: "US")
    entry = @investment_account.entries.create!(
      date: Date.current,
      amount: 500,
      name: "Buy TAXX",
      currency: "EUR",
      entryable: Trade.new(security: security, qty: 5, price: 100, currency: "EUR", investment_activity_label: "Buy")
    )
    trade = entry.entryable

    [ [ 1, 2 ], "raw-string-extra" ].each do |malformed|
      # Written past the model, as a provider or a migration writing SQL might.
      trade.update_column(:extra, malformed)

      get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
      assert_response :success, "show failed for extra = #{malformed.inspect}"
      assert_nil JSON.parse(response.body)["exchange_rate"]

      get api_v1_trades_url, params: { account_id: @investment_account.id, per_page: 100 }, headers: api_headers(read_only_api_key)
      assert_response :success, "index failed for extra = #{malformed.inspect}"
      trade_json = JSON.parse(response.body)["trades"].find { |row| row["id"] == trade.id }
      assert trade_json
      assert_nil trade_json["exchange_rate"]
    end
  end

  test "exchange rate is read the way the app converts it and only where it applies" do
    security = Security.create!(ticker: "TAXR", name: "Rate Parsing Security", country_code: "US")
    entry = @investment_account.entries.create!(
      date: Date.current,
      amount: 500,
      name: "Buy TAXR",
      currency: "EUR",
      entryable: Trade.new(security: security, qty: 5, price: 100, currency: "EUR", investment_activity_label: "Buy")
    )
    trade = entry.entryable

    # Float() would read "0x10" as 16; the app's to_d reads it as 0 and
    # refuses to convert with it.
    trade.update_column(:extra, { "exchange_rate" => "0x10" })
    get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
    assert_response :success
    assert_nil JSON.parse(response.body)["exchange_rate"]

    trade.update_column(:extra, { "exchange_rate" => "1.0850" })
    get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
    assert_equal 1.085, JSON.parse(response.body)["exchange_rate"]

    # A trade in the account's own currency is never converted, so a stored
    # rate on it is not exposed.
    entry.update_columns(currency: @investment_account.currency)
    trade.update_columns(currency: @investment_account.currency, extra: { "exchange_rate" => 1.085 })
    get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
    assert_nil JSON.parse(response.body)["exchange_rate"]
  end

  # The cost basis converts price and fee from trade.currency with the stored
  # rate (Holding::TradeCalculatorHelpers), and the web form and
  # PATCH /api/v1/trades/:id change entry.currency without touching
  # trade.currency, so the rate stays tied to the trade's currency there. The
  # cash balance (Balance::SyncCache) converts the amount from the entry's
  # currency with the same rate.
  test "exchange rate stays tied to the trade's currency when the entry's currency changes" do
    security = Security.create!(ticker: "TAXC", name: "Currency Mismatch Security", country_code: "US")
    entry = @investment_account.entries.create!(
      date: Date.current,
      amount: 100,
      name: "Buy TAXC",
      currency: "EUR",
      entryable: Trade.new(security: security, qty: 1, price: 100, currency: "EUR", investment_activity_label: "Buy",
        extra: { "exchange_rate" => 1.1 })
    )
    trade = entry.entryable

    patch api_v1_trade_url(trade), params: { trade: { currency: "GBP" } }, headers: api_headers(read_write_api_key)
    assert_response :success
    assert_equal "GBP", entry.reload.currency
    assert_equal "EUR", trade.reload.currency
    assert_equal 110, Money.new(trade.price, trade.currency).exchange_to("USD", custom_rate: trade.exchange_rate).amount,
      "the cost basis converts from the trade's currency with the stored rate"

    get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1.1, body["exchange_rate"]
    assert_equal "EUR", body["currency"]
    assert_equal "GBP", body["amount_currency"]

    get api_v1_trades_url, params: { account_id: @investment_account.id, per_page: 100 }, headers: api_headers(read_only_api_key)
    assert_response :success
    trade_json = JSON.parse(response.body)["trades"].find { |row| row["id"] == trade.id }
    assert_equal 1.1, trade_json["exchange_rate"]
    assert_equal "GBP", trade_json["amount_currency"]

    # Moving the entry into the account's currency leaves the rate the cost
    # basis still applies.
    patch api_v1_trade_url(trade), params: { trade: { currency: @investment_account.currency } }, headers: api_headers(read_write_api_key)
    assert_response :success
    get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
    assert_equal 1.1, JSON.parse(response.body)["exchange_rate"]

    # The other way round, the cost basis never applies the rate but the cash
    # balance converts the amount from the entry's currency with it.
    entry.update_columns(currency: "EUR")
    trade.update_columns(currency: @investment_account.currency)
    assert_equal 110, entry.reload.amount_money.exchange_to("USD", custom_rate: trade.reload.exchange_rate).amount,
      "the cash balance converts from the entry's currency with the stored rate"
    get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
    body = JSON.parse(response.body)
    assert_equal 1.1, body["exchange_rate"]
    assert_equal "USD", body["currency"]
    assert_equal "EUR", body["amount_currency"]

    # With both in the account's currency, neither path applies it.
    entry.update_columns(currency: @investment_account.currency)
    get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
    assert_nil JSON.parse(response.body)["exchange_rate"]
  end

  test "exchange rate compares currency codes regardless of case" do
    security = Security.create!(ticker: "TAXL", name: "Lower Case Currency Security", country_code: "US")
    entry = @investment_account.entries.create!(
      date: Date.current,
      amount: 100,
      name: "Buy TAXL",
      currency: "usd",
      entryable: Trade.new(security: security, qty: 1, price: 100, currency: "usd", investment_activity_label: "Buy",
        extra: { "exchange_rate" => 1.1 })
    )
    assert_equal 100, entry.amount_money.exchange_to("USD", custom_rate: entry.entryable.exchange_rate).amount,
      "Money treats usd as the account's currency"

    get api_v1_trade_url(entry.entryable), headers: api_headers(read_only_api_key)
    assert_response :success
    assert_nil JSON.parse(response.body)["exchange_rate"]
  end

  # A stored decimal can be positive and finite yet become 0.0 or Infinity
  # as a Float, which is what the response carries.
  test "exchange rate is null when the stored value does not fit a Float" do
    security = Security.create!(ticker: "TAXF", name: "Float Range Security", country_code: "US")
    entry = @investment_account.entries.create!(
      date: Date.current,
      amount: 100,
      name: "Buy TAXF",
      currency: "EUR",
      entryable: Trade.new(security: security, qty: 1, price: 100, currency: "EUR", investment_activity_label: "Buy")
    )
    trade = entry.entryable

    [ "1e-400", "1e400" ].each do |stored|
      trade.update_column(:extra, { "exchange_rate" => stored })
      get api_v1_trade_url(trade), headers: api_headers(read_only_api_key)
      assert_response :success
      assert_nil JSON.parse(response.body)["exchange_rate"], stored
      assert_nil trade.reload.numeric_exchange_rate, stored
    end
  end

  test "a member cannot list, read, change or add trades on accounts they cannot reach" do
    member = users(:family_member)
    member.api_keys.active.destroy_all
    key = ApiKey.create!(user: member, name: "Member RW", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    Redis.new.del("api_rate_limit:#{key.id}")

    private_account = member.family.accounts.create!(name: "Admin Private Brokerage", owner: @user, balance: 1_000,
                                                     currency: "USD", accountable: Investment.new)
    read_only = member.family.accounts.create!(name: "Admin Read-only Brokerage", owner: @user, balance: 1_000,
                                               currency: "USD", accountable: Investment.new)
    read_only.account_shares.create!(user: member, permission: "read_only", include_in_finances: true)
    hidden = create_trade(securities(:aapl), account: private_account, qty: 1, date: Date.current, price: 100).trade
    visible = create_trade(securities(:aapl), account: read_only, qty: 1, date: Date.current, price: 100).trade

    get "/api/v1/trades", params: { per_page: 100 }, headers: api_headers(key)
    ids = JSON.parse(response.body)["trades"].map { |t| t["id"] }
    assert_includes ids, visible.id, "the read-only share must still be listed, or this proves nothing"
    assert_not_includes ids, hidden.id

    get "/api/v1/trades/#{hidden.id}", headers: api_headers(key)
    assert_response :not_found

    get "/api/v1/trades/#{visible.id}", headers: api_headers(key)
    assert_response :success

    # Visible but not writable: 403, the caller can already read it.
    patch "/api/v1/trades/#{visible.id}", params: { trade: { qty: 2 } }, headers: api_headers(key)
    assert_response :forbidden
    assert_equal "You do not have permission to change this trade", JSON.parse(response.body)["message"]
    delete "/api/v1/trades/#{visible.id}", headers: api_headers(key)
    assert_response :forbidden
    assert_equal "You do not have permission to delete this trade", JSON.parse(response.body)["message"]
    assert Trade.exists?(visible.id)

    # Not visible at all: 404, existence is not revealed.
    patch "/api/v1/trades/#{hidden.id}", params: { trade: { qty: 2 } }, headers: api_headers(key)
    assert_response :not_found
    delete "/api/v1/trades/#{hidden.id}", headers: api_headers(key)
    assert_response :not_found
    assert Trade.exists?(hidden.id)

    post "/api/v1/trades", params: { trade: { account_id: read_only.id, type: "buy", date: Date.current,
                                              qty: 1, price: 100, ticker: "AAPL|XNAS" } }, headers: api_headers(key)
    assert_response :not_found
  end

  test "a full_control member can change and delete trades on a shared account" do
    member = users(:family_member)
    member.api_keys.active.destroy_all
    key = ApiKey.create!(user: member, name: "Member RW", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    Redis.new.del("api_rate_limit:#{key.id}")

    shared = member.family.accounts.create!(name: "Admin Shared Brokerage", owner: @user, balance: 1_000,
                                            currency: "USD", accountable: Investment.new)
    shared.account_shares.create!(user: member, permission: "full_control", include_in_finances: true)
    trade = create_trade(securities(:aapl), account: shared, qty: 1, date: Date.current, price: 100).trade

    patch "/api/v1/trades/#{trade.id}", params: { trade: { qty: 2 } }, headers: api_headers(key)
    assert_response :success

    delete "/api/v1/trades/#{trade.id}", headers: api_headers(key)
    assert_response :success
    assert_not Trade.exists?(trade.id)
  end


  test "a sale that stops being a disposal drops the lot it named" do
    @investment_account.update!(cost_basis_method: "fifo")
    security = Security.create!(ticker: "LOTFLIP", name: "LOTFLIP")
    buy = create_trade(security, account: @investment_account, qty: 40, price: 20, date: 3.days.ago.to_date)

    [ "buy", "sweep_out" ].each do |type|
      sale = create_trade(security, account: @investment_account, qty: -10, price: 25, date: 1.day.ago.to_date)
      sale.trade.update!(lot_source_entry: buy)

      patch api_v1_trade_url(sale.entryable_id), params: { trade: { type: type } }, headers: api_headers(read_write_api_key)

      assert_response :ok, type
      assert_nil sale.trade.reload.lot_source_entry_id, type
    end
  end

  test "a sale that names its lot reports the acquiring trade, in show and index" do
    @investment_account.update!(cost_basis_method: "fifo")
    security = Security.create!(ticker: "LOTAPI", name: "LOTAPI")
    buy = create_trade(security, account: @investment_account, qty: 40, price: 20, date: 3.days.ago.to_date)
    sale = create_trade(security, account: @investment_account, qty: -10, price: 25, date: 1.day.ago.to_date)
    other_sale = create_trade(security, account: @investment_account, qty: -5, price: 25, date: Date.current)
    sale.trade.update!(lot_source_entry: buy)

    get "/api/v1/trades/#{sale.entryable_id}", headers: api_headers(read_only_api_key)
    assert_response :success
    assert_equal buy.entryable_id, JSON.parse(response.body)["lot_source_trade_id"]

    get "/api/v1/trades", params: { account_id: @investment_account.id, per_page: 100 }, headers: api_headers(read_only_api_key)
    by_id = JSON.parse(response.body)["trades"].index_by { |trade| trade["id"] }
    assert_equal buy.entryable_id, by_id.fetch(sale.entryable_id)["lot_source_trade_id"]
    assert by_id.fetch(other_sale.entryable_id).key?("lot_source_trade_id")
    assert_nil by_id.fetch(other_sale.entryable_id)["lot_source_trade_id"]
  end

  private

    def category_ids_from_every_source
      {
        "own" => categories(:food_and_drink).id,
        "foreign" => families(:empty).categories.create!(name: "Other family category", color: "#123456", lucide_icon: "circle").id,
        "unknown" => SecureRandom.uuid
      }
    end

    def create_buy_trade(ticker, fee: nil)
      security = Security.create!(ticker: ticker, name: "#{ticker} Security", country_code: "US")
      post "/api/v1/trades",
        params: { trade: {
          account_id: @investment_account.id,
          type: "buy",
          date: Date.current,
          qty: 5,
          price: 100,
          fee: fee,
          currency: "USD",
          security_id: security.id
        }.compact },
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
