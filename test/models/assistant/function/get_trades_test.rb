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
end
