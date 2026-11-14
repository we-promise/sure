require "test_helper"

class Assistant::Function::GetTradesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:investment)
    @function = Assistant::Function::GetTrades.new(@user)
  end

  test "lists trades with pagination metadata" do
    result = @function.call("page" => 1)

    assert_equal 1, result[:total_results]
    assert_equal 1, result[:page]
    assert_equal Assistant::Function::GetTrades.default_page_size, result[:page_size]
    assert_equal 1, result[:total_pages]
    assert_equal 1, result[:trades].size

    trade = result[:trades].first
    assert_equal "AAPL", trade[:security][:ticker]
    assert_equal "buy", trade[:side]
    assert_equal 10.0, trade[:qty]
    assert_equal 214.0, trade[:price]
    assert_equal "USD", trade[:currency]
    assert_equal @account.name, trade[:account]
  end

  test "clamps a page beyond the last one and reports the clamped page" do
    result = @function.call("page" => 2)

    # Pagy (like the other paginated tools) clamps the page, so an out-of-range
    # request returns the last page's rows and reports the page actually served.
    assert_equal 1, result[:page]
    assert_equal 1, result[:total_pages]
    assert_equal 1, result[:trades].size
    assert_equal 1, result[:total_results]
  end

  test "filters by side" do
    buys = @function.call("page" => 1, "side" => "buy")
    sells = @function.call("page" => 1, "side" => "sell")

    assert_equal 1, buys[:total_results]
    assert_equal 0, sells[:total_results]
  end

  test "filters by security ticker" do
    aapl = @function.call("page" => 1, "securities" => [ "AAPL" ])
    msft = @function.call("page" => 1, "securities" => [ "MSFT" ])

    assert_equal 1, aapl[:total_results]
    assert_equal 0, msft[:total_results]
  end

  test "filters by account name" do
    matching = @function.call("page" => 1, "accounts" => [ @account.name ])
    other = @function.call("page" => 1, "accounts" => [ accounts(:depository).name ])

    assert_equal 1, matching[:total_results]
    assert_equal 0, other[:total_results]
  end

  test "filters by date range" do
    recent = @function.call("page" => 1, "start_date" => 7.days.ago.to_date.iso8601, "end_date" => Date.current.iso8601)
    old = @function.call("page" => 1, "start_date" => "2020-01-01", "end_date" => "2020-12-31")

    assert_equal 1, recent[:total_results]
    assert_equal 0, old[:total_results]
  end

  test "omits dividends, interest, fees, sweeps and reinvestments" do
    create_labeled_trade(label: "Dividend", qty: 0, name: "Dividend: AAPL")
    create_labeled_trade(label: "Interest", qty: 0, name: "Interest: AAPL")
    create_labeled_trade(label: "Fee", qty: 0, name: "Fee: AAPL")
    create_labeled_trade(label: "Sweep In", qty: 3, name: "Sweep In AAPL")
    create_labeled_trade(label: "Sweep Out", qty: -3, name: "Sweep Out AAPL")
    create_labeled_trade(label: "Reinvestment", qty: 2, name: "Reinvestment AAPL")
    create_labeled_trade(label: "Sell", qty: -4, name: "Sell AAPL")

    result = @function.call("page" => 1)
    names = result[:trades].map { |trade| trade[:name] }

    assert_equal 2, result[:total_results]
    assert_includes names, "Purchase 10 shares of AAPL"
    assert_includes names, "Sell AAPL"
    [ "Dividend: AAPL", "Interest: AAPL", "Fee: AAPL", "Sweep In AAPL", "Sweep Out AAPL", "Reinvestment AAPL" ].each do |excluded|
      assert_not_includes names, excluded
    end

    sell = result[:trades].find { |trade| trade[:name] == "Sell AAPL" }
    assert_equal "sell", sell[:side]
    assert_equal 4.0, sell[:qty]

    buys = @function.call("page" => 1, "side" => "buy")
    assert_equal [ "Purchase 10 shares of AAPL" ], buys[:trades].map { |trade| trade[:name] }

    sells = @function.call("page" => 1, "side" => "sell")
    assert_equal [ "Sell AAPL" ], sells[:trades].map { |trade| trade[:name] }
  end

  test "treats an unlabeled nonzero quantity as a buy or sell" do
    create_labeled_trade(label: nil, qty: 5, name: "Legacy buy")
    create_labeled_trade(label: nil, qty: -2, name: "Legacy sell")
    create_labeled_trade(label: nil, qty: 0, name: "Legacy cash")

    result = @function.call("page" => 1)
    by_name = result[:trades].index_by { |trade| trade[:name] }

    assert_equal "buy", by_name["Legacy buy"][:side]
    assert_equal 5.0, by_name["Legacy buy"][:qty]
    assert_equal "sell", by_name["Legacy sell"][:side]
    assert_equal 2.0, by_name["Legacy sell"][:qty]
    assert_nil by_name["Legacy cash"]

    buy_names = @function.call("page" => 1, "side" => "buy")[:trades].map { |trade| trade[:name] }
    assert_includes buy_names, "Legacy buy"
    assert_not_includes buy_names, "Legacy sell"
    assert_not_includes buy_names, "Legacy cash"

    sell_names = @function.call("page" => 1, "side" => "sell")[:trades].map { |trade| trade[:name] }
    assert_includes sell_names, "Legacy sell"
    assert_not_includes sell_names, "Legacy buy"
    assert_not_includes sell_names, "Legacy cash"
  end

  test "rejects an invalid side and invalid dates" do
    side = @function.call("page" => 1, "side" => "transfer")
    assert_equal "invalid_side", side[:error]

    date = @function.call("page" => 1, "start_date" => "not-a-date")
    assert_equal "invalid_date", date[:error]
  end

  test "exposes a tool definition on the shared registry" do
    assert_includes Assistant.function_classes(@user).map(&:name), "get_trades"

    definition = @function.to_definition
    assert_equal "get_trades", definition[:name]
    assert_equal [ "page" ], definition[:params_schema][:required]
    assert_equal %w[buy sell], definition[:params_schema][:properties][:side][:enum]
  end

  private
    def create_labeled_trade(label:, qty:, name:)
      @account.entries.create!(
        name: name,
        date: Date.current,
        amount: qty.to_d * 10,
        currency: "USD",
        entryable: Trade.new(
          security: securities(:aapl),
          qty: qty,
          price: 10,
          currency: "USD",
          investment_activity_label: label
        )
      )
    end
end
