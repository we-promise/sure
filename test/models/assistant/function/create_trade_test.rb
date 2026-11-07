require "test_helper"

class Assistant::Function::CreateTradeTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:investment)
    @function = Assistant::Function::CreateTrade.new(@user)
  end

  test "records a buy and computes the entry amount from qty, price and fee" do
    Account.any_instance.expects(:sync_later).once

    assert_difference [ "Trade.count", "Entry.count" ], 1 do
      @result = @function.call(
        "account_id" => @account.id,
        "date" => "2026-10-10",
        "type" => "buy",
        "ticker" => "AAPL|XNAS",
        "qty" => 10,
        "price" => 214.5,
        "fee" => 4.9
      )
    end

    assert_equal true, @result[:success]
    assert_equal true, @result[:created]
    assert_equal "buy", @result[:trade][:side]
    assert_equal 10.0, @result[:trade][:qty]
    assert_equal 214.5, @result[:trade][:price]
    assert_equal 4.9, @result[:trade][:fee]
    assert_equal "USD", @result[:trade][:currency]
    assert_equal "AAPL", @result[:trade][:security][:ticker]
    assert_equal @account.name, @result[:trade][:account]

    entry = Entry.find(@result[:trade][:entry_id])
    assert_equal @account, entry.account
    assert_equal Date.new(2026, 10, 10), entry.date
    assert_equal BigDecimal("2149.9"), entry.amount
    assert_equal "Trade", entry.entryable_type
    assert entry.user_modified?
    assert entry.protected_from_sync?
  end

  test "records a sell with a negative quantity and amount" do
    @result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-10-11",
      "type" => "sell",
      "ticker" => "AAPL|XNAS",
      "qty" => 4,
      "price" => 220
    )

    assert_equal true, @result[:success]
    assert_equal "sell", @result[:trade][:side]
    assert_equal 4.0, @result[:trade][:qty]

    trade = Trade.find(@result[:trade][:id])
    assert_equal BigDecimal("-4"), trade.qty
    assert_equal BigDecimal("-880"), trade.entry.amount
  end

  test "falls back to the account currency when none is given" do
    @result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-10-10",
      "type" => "buy",
      "ticker" => "AAPL|XNAS",
      "qty" => 1,
      "price" => 100
    )

    assert_equal @account.currency, @result[:trade][:currency]
  end

  test "accepts a manual ticker for assets the provider does not price" do
    @result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-10-10",
      "type" => "buy",
      "manual_ticker" => "OFFLINE-FUND",
      "qty" => 2,
      "price" => 1000
    )

    assert_equal true, @result[:success]
    assert_equal "OFFLINE-FUND", @result[:trade][:security][:ticker]
  end

  test "rejects an account that does not support trades" do
    assert_no_difference "Trade.count" do
      @result = @function.call(
        "account_id" => accounts(:depository).id,
        "date" => "2026-10-10",
        "type" => "buy",
        "ticker" => "AAPL|XNAS",
        "qty" => 1,
        "price" => 100
      )
    end

    assert_equal false, @result[:success]
    assert_equal "unsupported_account", @result[:error]
  end

  test "rejects an unknown account id" do
    @result = @function.call(
      "account_id" => SecureRandom.uuid,
      "date" => "2026-10-10",
      "type" => "buy",
      "ticker" => "AAPL|XNAS",
      "qty" => 1,
      "price" => 100
    )

    assert_equal "account_not_found", @result[:error]
  end

  test "rejects an unsupported type" do
    @result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-10-10",
      "type" => "dividend",
      "ticker" => "AAPL|XNAS",
      "qty" => 1,
      "price" => 100
    )

    assert_equal "invalid_type", @result[:error]
  end

  test "rejects a present fee that is unparsable or not a non-negative finite number" do
    [ "4.90 USD", "N/A", true, "Infinity", "NaN", -1 ].each do |fee|
      assert_no_difference "Trade.count" do
        result = @function.call(trade_params("fee" => fee))
        assert_equal "invalid_fee", result[:error], fee.inspect
      end
    end
  end

  test "defaults a blank or omitted fee to zero" do
    omitted = @function.call(trade_params)
    assert_equal true, omitted[:success]
    assert_equal 0.0, omitted[:trade][:fee]

    [ nil, "", "   ", 0 ].each do |fee|
      result = @function.call(trade_params("fee" => fee))
      assert_equal true, result[:success], fee.inspect
      assert_equal 0.0, result[:trade][:fee]
    end
  end

  test "rejects a non-finite quantity or price" do
    [ "Infinity", "NaN" ].each do |qty|
      assert_no_difference "Trade.count" do
        result = @function.call(trade_params("qty" => qty))
        assert_equal "invalid_quantity", result[:error], qty.inspect
      end
    end

    [ "Infinity", "NaN" ].each do |price|
      assert_no_difference "Trade.count" do
        result = @function.call(trade_params("price" => price))
        assert_equal "invalid_price", result[:error], price.inspect
      end
    end
  end

  test "returns the recorded trade with a warning when account sync cannot be enqueued" do
    Account.any_instance.stubs(:sync_later).raises(StandardError, "job backend unavailable")

    assert_difference "Trade.count", 1 do
      @result = @function.call(trade_params("manual_ticker" => "SYNC-WARN"))
    end

    assert_equal true, @result[:success]
    assert_equal true, @result[:created]
    assert_match(/could not be enqueued \(StandardError\)/, @result[:warning])

    entry = Entry.find(@result[:trade][:entry_id])
    assert entry.user_modified?
    assert entry.persisted?
  end

  test "rejects a non positive quantity or price" do
    quantity = @function.call(
      "account_id" => @account.id,
      "date" => "2026-10-10",
      "type" => "buy",
      "ticker" => "AAPL|XNAS",
      "qty" => 0,
      "price" => 100
    )
    assert_equal "invalid_quantity", quantity[:error]

    price = @function.call(
      "account_id" => @account.id,
      "date" => "2026-10-10",
      "type" => "buy",
      "ticker" => "AAPL|XNAS",
      "qty" => 1,
      "price" => -1
    )
    assert_equal "invalid_price", price[:error]
  end

  test "requires a ticker or a manual ticker" do
    @result = @function.call(
      "account_id" => @account.id,
      "date" => "2026-10-10",
      "type" => "buy",
      "qty" => 1,
      "price" => 100
    )

    assert_equal "security_required", @result[:error]
  end

  test "rejects an invalid date and an invalid currency" do
    date = @function.call(
      "account_id" => @account.id,
      "date" => "10/10/2026",
      "type" => "buy",
      "ticker" => "AAPL|XNAS",
      "qty" => 1,
      "price" => 100
    )
    assert_equal "invalid_date", date[:error]

    currency = @function.call(
      "account_id" => @account.id,
      "date" => "2026-10-10",
      "type" => "buy",
      "ticker" => "AAPL|XNAS",
      "qty" => 1,
      "price" => 100,
      "currency" => "ABC"
    )
    assert_equal "invalid_currency", currency[:error]
  end

  test "exposes a tool definition on the shared registry" do
    assert_includes Assistant.function_classes(@user).map(&:name), "create_trade"

    definition = @function.to_definition
    assert_equal "create_trade", definition[:name]
    assert_equal %w[account_id date type qty price], definition[:params_schema][:required]
    assert_equal %w[buy sell], definition[:params_schema][:properties][:type][:enum]
  end

  private
    def trade_params(overrides = {})
      {
        "account_id" => @account.id,
        "date" => "2026-10-10",
        "type" => "buy",
        "manual_ticker" => "OFFLINE-FUND",
        "qty" => 1,
        "price" => 10
      }.merge(overrides)
    end
end
