require "test_helper"

class ExchangeRate::StoredRateTableTest < ActiveSupport::TestCase
  setup do
    ExchangeRate.where(from_currency: %w[JPY CHF], to_currency: "USD").delete_all
    @d1, @d2, @d3 = 10.days.ago.to_date, 5.days.ago.to_date, 2.days.ago.to_date
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: @d1, rate: 0.0066)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: @d2, rate: 0.0068)
  end

  test "uses the stored rate on or before each date, else the earliest after it, like find_stored_rate" do
    dates = [ @d1 - 3, @d1, @d1 + 1, @d2, @d3 ]
    table = ExchangeRate::StoredRateTable.new(from: [ "JPY" ], to: "USD", dates: dates)

    dates.each do |date|
      assert_equal ExchangeRate.find_stored_rate(from: "JPY", to: "USD", date: date).rate, table.rate("JPY", date), "on #{date}"
    end
  end

  test "is 1 for the target currency and nil without any stored rate" do
    table = ExchangeRate::StoredRateTable.new(from: [ "USD", "CHF" ], to: "USD", dates: [ @d3 ])

    assert_equal 1, table.rate("USD", @d3)
    assert_nil table.rate("CHF", @d3)
    assert_nil table.convert(100, from: "CHF", date: @d3)
  end

  test "never asks the provider and loads in a constant number of queries" do
    ExchangeRate.expects(:find_or_fetch_rate).never
    ExchangeRate.expects(:provider).never

    count = ->(dates) do
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        table = ExchangeRate::StoredRateTable.new(from: [ "JPY" ], to: "USD", dates: dates)
        dates.each { |date| table.convert(1000, from: "JPY", date: date) }
      end
      n
    end

    first = @d1 - 30
    assert_equal count.([ first, @d3 ]), count.((0..40).map { |i| first + i }), "more dates do not add queries"
  end
end
