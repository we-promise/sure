require "test_helper"
require "ostruct"

class Security::Price::ImporterTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock
    @security = Security.create!(ticker: "AAPL")
  end

  test "syncs missing prices from provider" do
    Security::Price.delete_all

    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: 2.days.ago.to_date, price: 150, currency: "USD"),
      OpenStruct.new(security: @security, date: 1.day.ago.to_date, price: 155, currency: "USD"),
      OpenStruct.new(security: @security, date: Date.current, price: 160, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(2.days.ago.to_date), end_date: Date.current)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: 2.days.ago.to_date,
      end_date: Date.current
    ).import_provider_prices

    db_prices = Security::Price.where(security: @security, date: 2.days.ago.to_date..Date.current).order(:date)

    assert_equal 3, db_prices.count
    assert_equal [ 150, 155, 160 ], db_prices.map(&:price)
  end

  test "syncs diff when some prices already exist" do
    Security::Price.delete_all

    # Pre-populate DB with first two days
    Security::Price.create!(security: @security, date: 3.days.ago.to_date, price: 140, currency: "USD")
    Security::Price.create!(security: @security, date: 2.days.ago.to_date, price: 145, currency: "USD")

    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: 1.day.ago.to_date, price: 150, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(1.day.ago.to_date), end_date: Date.current)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: 3.days.ago.to_date,
      end_date: Date.current
    ).import_provider_prices

    db_prices = Security::Price.where(security: @security).order(:date)
    assert_equal 4, db_prices.count
    assert_equal [ 140, 145, 150, 150 ], db_prices.map(&:price)
  end

  test "no provider calls when all prices exist" do
    Security::Price.delete_all

    (3.days.ago.to_date..Date.current).each_with_index do |date, idx|
      Security::Price.create!(security: @security, date:, price: 100 + idx, currency: "USD")
    end

    @provider.expects(:fetch_security_prices).never

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: 3.days.ago.to_date,
      end_date: Date.current
    ).import_provider_prices
  end

  test "full upsert if clear_cache is true" do
    Security::Price.delete_all

    # Seed DB with stale prices
    (2.days.ago.to_date..Date.current).each do |date|
      Security::Price.create!(security: @security, date:, price: 100, currency: "USD")
    end

    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: 2.days.ago.to_date, price: 150, currency: "USD"),
      OpenStruct.new(security: @security, date: 1.day.ago.to_date, price: 155, currency: "USD"),
      OpenStruct.new(security: @security, date: Date.current,        price: 160, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(2.days.ago.to_date), end_date: Date.current)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: 2.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    ).import_provider_prices

    db_prices = Security::Price.where(security: @security).order(:date)
    assert_equal [ 150, 155, 160 ], db_prices.map(&:price)
  end

  test "clamps end_date to today when future date is provided" do
    Security::Price.delete_all

    future_date = Date.current + 3.days

    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: Date.current, price: 165, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(Date.current), end_date: Date.current)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: Date.current,
      end_date: future_date
    ).import_provider_prices

    assert_equal 1, Security::Price.count
  end

  test "marks prices as not provisional when from provider" do
    Security::Price.delete_all

    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: 1.day.ago.to_date, price: 150, currency: "USD"),
      OpenStruct.new(security: @security, date: Date.current, price: 155, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(1.day.ago.to_date), end_date: Date.current)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: 1.day.ago.to_date,
      end_date: Date.current
    ).import_provider_prices

    db_prices = Security::Price.where(security: @security).order(:date)
    assert db_prices.all? { |p| p.provisional == false }, "All prices from provider should not be provisional"
  end

  test "marks gap-filled weekend prices as provisional" do
    Security::Price.delete_all

    # Find a recent Saturday
    saturday = Date.current
    saturday -= 1.day until saturday.saturday?
    friday = saturday - 1.day

    # Provider only returns Friday's price, not Saturday
    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: friday, price: 150, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(friday), end_date: saturday)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: friday,
      end_date: saturday
    ).import_provider_prices

    saturday_price = Security::Price.find_by(security: @security, date: saturday)
    # Weekend gap-filled prices are now provisional so they can be fixed
    # via cascade when the next weekday sync fetches the correct Friday price
    assert saturday_price.provisional, "Weekend gap-filled price should be provisional"
  end

  test "marks gap-filled recent weekday prices as provisional" do
    Security::Price.delete_all

    # Find a recent weekday that's not today
    weekday = 1.day.ago.to_date
    weekday -= 1.day while weekday.saturday? || weekday.sunday?

    # Start from 2 days before the weekday
    start_date = weekday - 1.day
    start_date -= 1.day while start_date.saturday? || start_date.sunday?

    # Provider only returns start_date price, not the weekday
    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: start_date, price: 150, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(start_date), end_date: weekday)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: start_date,
      end_date: weekday
    ).import_provider_prices

    weekday_price = Security::Price.find_by(security: @security, date: weekday)
    # Only recent weekdays should be provisional
    if weekday >= 3.days.ago.to_date
      assert weekday_price.provisional, "Gap-filled recent weekday price should be provisional"
    else
      assert_not weekday_price.provisional, "Gap-filled old weekday price should not be provisional"
    end
  end

  test "retries fetch when refetchable provisional prices exist" do
    Security::Price.delete_all

    # Skip if today is a weekend
    return if Date.current.saturday? || Date.current.sunday?

    # Pre-populate with provisional price for today
    Security::Price.create!(
      security: @security,
      date: Date.current,
      price: 100,
      currency: "USD",
      provisional: true
    )

    # Provider now returns today's actual price
    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: Date.current, price: 165, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(Date.current), end_date: Date.current)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: Date.current,
      end_date: Date.current
    ).import_provider_prices

    db_price = Security::Price.find_by(security: @security, date: Date.current)
    assert_equal 165, db_price.price, "Price should be updated from provider"
    assert_not db_price.provisional, "Price should no longer be provisional after provider returns real price"
  end

  test "skips fetch when all prices are non-provisional" do
    Security::Price.delete_all

    # Create non-provisional prices for the range
    (3.days.ago.to_date..Date.current).each_with_index do |date, idx|
      Security::Price.create!(security: @security, date: date, price: 100 + idx, currency: "USD", provisional: false)
    end

    @provider.expects(:fetch_security_prices).never

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: 3.days.ago.to_date,
      end_date: Date.current
    ).import_provider_prices
  end

  test "does not mark old gap-filled prices as provisional" do
    Security::Price.delete_all

    # Use dates older than the lookback window
    old_date = 10.days.ago.to_date
    old_date -= 1.day while old_date.saturday? || old_date.sunday?
    start_date = old_date - 1.day
    start_date -= 1.day while start_date.saturday? || start_date.sunday?

    # Provider only returns start_date price
    provider_response = provider_success_response([
      OpenStruct.new(security: @security, date: start_date, price: 150, currency: "USD")
    ])

    @provider.expects(:fetch_security_prices)
             .with(symbol: @security.ticker, exchange_operating_mic: @security.exchange_operating_mic,
                   start_date: get_provider_fetch_start_date(start_date), end_date: old_date)
             .returns(provider_response)

    Security::Price::Importer.new(
      security: @security,
      security_provider: @provider,
      start_date: start_date,
      end_date: old_date
    ).import_provider_prices

    old_price = Security::Price.find_by(security: @security, date: old_date)
    assert_not old_price.provisional, "Old gap-filled price should not be provisional"
  end

  test "provisional weekend prices get fixed via cascade from Friday" do
    Security::Price.delete_all

    # Find a recent Monday
    monday = Date.current
    monday += 1.day until monday.monday?
    friday = monday - 3.days
    saturday = monday - 2.days
    sunday = monday - 1.day

    travel_to monday do
      # Create provisional weekend prices with WRONG values (simulating stale data)
      Security::Price.create!(security: @security, date: saturday, price: 50, currency: "USD", provisional: true)
      Security::Price.create!(security: @security, date: sunday, price: 50, currency: "USD", provisional: true)

      # Provider returns Friday and Monday prices, but NOT weekend (markets closed)
      provider_response = provider_success_response([
        OpenStruct.new(security: @security, date: friday, price: 150, currency: "USD"),
        OpenStruct.new(security: @security, date: monday, price: 155, currency: "USD")
      ])

      @provider.expects(:fetch_security_prices).returns(provider_response)

      Security::Price::Importer.new(
        security: @security,
        security_provider: @provider,
        start_date: friday,
        end_date: monday
      ).import_provider_prices

      # Friday should have real price from provider
      friday_price = Security::Price.find_by(security: @security, date: friday)
      assert_equal 150, friday_price.price
      assert_not friday_price.provisional, "Friday should not be provisional (real price)"

      # Saturday should be gap-filled from Friday (150), not old wrong value (50)
      saturday_price = Security::Price.find_by(security: @security, date: saturday)
      assert_equal 150, saturday_price.price, "Saturday should use Friday's price via cascade"
      assert saturday_price.provisional, "Saturday should be provisional (gap-filled)"

      # Sunday should be gap-filled from Saturday (150)
      sunday_price = Security::Price.find_by(security: @security, date: sunday)
      assert_equal 150, sunday_price.price, "Sunday should use Friday's price via cascade"
      assert sunday_price.provisional, "Sunday should be provisional (gap-filled)"

      # Monday should have real price from provider
      monday_price = Security::Price.find_by(security: @security, date: monday)
      assert_equal 155, monday_price.price
      assert_not monday_price.provisional, "Monday should not be provisional (real price)"
    end
  end

  test "uses recent prices for gap-fill when effective_start_date skips old dates" do
    Security::Price.delete_all

    # Use travel_to to ensure we're on a weekday for consistent test behavior
    # Find the next weekday if today is a weekend
    test_date = Date.current
    test_date += 1.day while test_date.saturday? || test_date.sunday?

    travel_to test_date do
      # Simulate: old price exists from first trade date (30 days ago) with STALE value
      old_date = 30.days.ago.to_date
      stale_price = 50

      # Fully populate DB from old_date through yesterday so effective_start_date = today
      # Use stale price for old dates, then recent price for recent dates
      (old_date..1.day.ago.to_date).each do |date|
        # Use stale price for dates older than lookback window, recent price for recent dates
        price = date < 7.days.ago.to_date ? stale_price : 150
        Security::Price.create!(security: @security, date: date, price: price, currency: "USD")
      end

      # Provider returns yesterday's price (155) - DIFFERENT from DB (150) to prove we use provider
      # Provider does NOT return today (simulating market closed)
      provider_response = provider_success_response([
        OpenStruct.new(security: @security, date: 1.day.ago.to_date, price: 155, currency: "USD")
      ])

      @provider.expects(:fetch_security_prices).returns(provider_response)

      Security::Price::Importer.new(
        security: @security,
        security_provider: @provider,
        start_date: old_date,
        end_date: Date.current
      ).import_provider_prices

      today_price = Security::Price.find_by(security: @security, date: Date.current)

      # effective_start_date should be today (only missing date)
      # start_price_value should use provider's yesterday (155), not stale old DB price (50)
      # Today should gap-fill from that recent price
      assert_equal 155, today_price.price, "Gap-fill should use recent provider price, not stale old price"
      # Should be provisional since gap-filled for recent weekday
      assert today_price.provisional, "Current weekday gap-filled price should be provisional"
    end
  end

  private
    def get_provider_fetch_start_date(start_date)
      start_date - Security::Price::Importer::PROVISIONAL_LOOKBACK_DAYS.days
    end
end
