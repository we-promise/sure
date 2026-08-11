require "test_helper"

class Provider::WiseTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Wise.new("test_token", base_url: "https://api.wise.com")
  end

  test "chunks balance statement requests into windows under the 469-day limit" do
    start_date = Date.new(2015, 4, 12)
    end_date = Date.new(2018, 4, 30)

    expected_windows = []
    window_start = start_date
    while window_start <= end_date
      window_end = [ window_start + (Provider::Wise::MAX_STATEMENT_DAYS - 1), end_date ].min
      expected_windows << {
        interval_start: window_start.beginning_of_day,
        interval_end: window_end.end_of_day
      }
      window_start = window_end + 1.day
    end
    assert_operator expected_windows.size, :>, 1

    expected_windows.each do |window|
      @provider.expects(:get_balance_statement)
        .with("111", "222", currency: "EUR",
              interval_start: window[:interval_start],
              interval_end: window[:interval_end])
        .returns({ "transactions" => [] })
        .once
    end

    result = @provider.get_balance_statements("111", "222", currency: "EUR", start_date: start_date, end_date: end_date)

    assert_equal [], result
  end

  test "uses a single request when the range fits within the limit" do
    @provider.stubs(:get_balance_statement)
      .with("111", "222", currency: "EUR",
            interval_start: Date.new(2018, 1, 1).beginning_of_day,
            interval_end: Date.new(2018, 4, 30).end_of_day)
      .returns({ "transactions" => [] })

    result = @provider.get_balance_statements(
      "111",
      "222",
      currency: "EUR",
      start_date: Date.new(2018, 1, 1),
      end_date: Date.new(2018, 4, 30)
    )

    assert_equal [], result
  end

  test "retries a rate-limited window without restarting earlier windows" do
    error = Provider::Wise::WiseError.new("rate limited", :rate_limited)
    @provider.stubs(:sleep)
    @provider.stubs(:get_balance_statement)
      .raises(error).then
      .returns({ "transactions" => [] }).then
      .returns({ "transactions" => [] })

    result = @provider.get_balance_statements(
      "111",
      "222",
      currency: "EUR",
      start_date: Date.new(2018, 1, 1),
      end_date: Date.new(2018, 4, 30)
    )

    assert_equal [], result
  end
end
