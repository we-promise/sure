require "test_helper"

class ExchangeRate::UsdCrossTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock
    @day1 = Date.new(2026, 10, 19)
    @day2 = @day1 + 1
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "multiplies only USD legs observed on the same date, in date order" do
    day3 = @day2 + 1
    @provider.expects(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: day3)
             .returns(provider_success_response([ rate(day3, "KZT", "USD", 0.003), rate(@day2, "KZT", "USD", 0.0022), rate(@day1, "KZT", "USD", 0.002) ]))
    @provider.expects(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: day3)
             .returns(provider_success_response([ rate(day3, "USD", "RUB", 90), rate(@day1, "USD", "RUB", 80) ]))

    rates = ExchangeRate::UsdCross.new(@provider)
      .rates(from: "KZT", to: "RUB", start_date: @day1, end_date: day3, error: StandardError.new("no KZT/RUB"))

    assert_equal [ @day1, day3 ], rates.map(&:date)
    assert_equal [ 0.16, 0.27 ], rates.map { |r| r.rate.to_f }
    assert_equal [ "KZT", "RUB" ], [ rates.first.from, rates.first.to ]

    entry = DebugLogEntry.where(category: "exchange_rates", level: "info").recent.first
    assert_equal "ExchangeRate::UsdCross", entry.source
    assert_equal "no KZT/RUB", entry.metadata["direct_error"]
  end

  test "skips a product that rounds to a zero rate" do
    @provider.stubs(:fetch_exchange_rates).with(from: "AAA", to: "USD", start_date: @day1, end_date: @day1)
             .returns(provider_success_response([ rate(@day1, "AAA", "USD", 0.0000001) ]))
    @provider.stubs(:fetch_exchange_rates).with(from: "USD", to: "BBB", start_date: @day1, end_date: @day1)
             .returns(provider_success_response([ rate(@day1, "USD", "BBB", 0.000001) ]))

    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "AAA", to: "BBB", start_date: @day1, end_date: @day1)
  end

  test "is empty without asking the provider when it is rate limiting or rejecting requests" do
    @provider.expects(:fetch_exchange_rates).never
    cross = ExchangeRate::UsdCross.new(@provider)

    [ Provider::TwelveData::RateLimitError.new("slow down"), Provider::YahooFinance::AuthenticationError.new("no crumb") ].each do |error|
      assert_empty cross.rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2, error: error)
    end
  end

  test "skips days before the first USD rate" do
    @provider.stubs(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: @day2)
             .returns(provider_success_response([ rate(@day1, "KZT", "USD", 0.002), rate(@day2, "KZT", "USD", 0.0022) ]))
    @provider.stubs(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: @day2)
             .returns(provider_success_response([ rate(@day2, "USD", "RUB", 80) ]))

    rates = ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)

    assert_equal [ @day2 ], rates.map(&:date)
  end

  test "is empty without asking the provider when a side is USD" do
    @provider.expects(:fetch_exchange_rates).never

    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "USD", to: "RUB", start_date: @day1, end_date: @day2)
    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "RUB", to: "USD", start_date: @day1, end_date: @day2)
  end

  test "is empty without asking a provider that cannot quote both USD legs" do
    moex = Provider::MoexPublic.new
    moex.expects(:fx_history).never

    assert_empty ExchangeRate::UsdCross.new(moex).rates(from: "RUB", to: "KZT", start_date: @day1, end_date: @day2)
  end

  test "is empty without asking the provider for a pair it has quoted before" do
    ExchangeRatePair.record_direct_quote(from: "KZT", to: "RUB")
    @provider.expects(:fetch_exchange_rates).never

    assert_empty ExchangeRate::UsdCross.new(@provider)
      .rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2, error: StandardError.new("timeout"))
  end

  test "is empty when the first leg fails, without fetching the second, and logs the leg" do
    @provider.expects(:fetch_exchange_rates).once.returns(provider_error_response(StandardError.new("no pair")))

    assert_difference -> { DebugLogEntry.where(category: "exchange_rates", level: "warn").count }, 1 do
      assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)
    end

    metadata = DebugLogEntry.where(category: "exchange_rates").recent.first.metadata
    assert_equal({ "from" => "KZT", "to" => "USD", "error" => "no pair" }, metadata.slice("from", "to", "error"))
  end

  test "does not ask again for a pair whose first leg just failed, nor log it again" do
    @provider.expects(:fetch_exchange_rates).once.returns(provider_error_response(StandardError.new("no pair")))
    cross = ExchangeRate::UsdCross.new(@provider)

    assert_empty cross.rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)

    assert_no_difference -> { DebugLogEntry.where(category: "exchange_rates").count } do
      assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)
    end
  end

  test "does not let a miss for other dates hide the pair" do
    old_day = Date.new(2010, 1, 4)
    @provider.stubs(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: old_day, end_date: old_day)
             .returns(provider_success_response([]))
    @provider.stubs(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: @day1)
             .returns(provider_success_response([ rate(@day1, "KZT", "USD", 0.002) ]))
    @provider.stubs(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: @day1)
             .returns(provider_success_response([ rate(@day1, "USD", "RUB", 80) ]))

    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: old_day, end_date: old_day)
    assert_equal 1, ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day1).size
  end

  test "remembers a pair whose second leg has no rates" do
    @provider.expects(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: @day2)
             .returns(provider_success_response([ rate(@day1, "KZT", "USD", 0.002) ]))
    @provider.expects(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: @day2)
             .returns(provider_error_response(StandardError.new("no pair")))

    2.times { assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2) }
  end

  test "asks again once the remembered miss expires, and a later success is derived" do
    @provider.stubs(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: @day2)
             .returns(provider_error_response(StandardError.new("down"))).then
             .returns(provider_success_response([ rate(@day1, "KZT", "USD", 0.002) ]))
    @provider.expects(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: @day2)
             .returns(provider_success_response([ rate(@day1, "USD", "RUB", 80) ]))

    assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)

    travel_to(ExchangeRate::UsdCross::MISS_TTL.from_now + 1.minute) do
      rates = ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)
      assert_equal [ 0.16 ], rates.map { |r| r.rate.to_f }
    end
  end

  test "forgets a remembered miss when a lookup that began before it was recorded derives the pair" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    key = "usd_cross_miss:#{@provider.class.name}:KZT:RUB:#{@day1}:#{@day1}"
    cache.write(key, true)
    cache.stubs(:exist?).with(key).returns(false)
    @provider.stubs(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: @day1)
             .returns(provider_success_response([ rate(@day1, "KZT", "USD", 0.002) ]))
    @provider.stubs(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: @day1)
             .returns(provider_success_response([ rate(@day1, "USD", "RUB", 80) ]))

    assert_equal 1, ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day1).size
    assert_not cache.read(key)
  end

  test "remembers a miss for its own provider and pair only" do
    other = Provider::YahooFinance.new
    @provider.expects(:fetch_exchange_rates).once.returns(provider_error_response(StandardError.new("no pair")))
    other.expects(:fetch_exchange_rates).twice.returns(provider_error_response(StandardError.new("no pair")))

    ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)
    ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)
    ExchangeRate::UsdCross.new(other).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2)
    ExchangeRate::UsdCross.new(other).rates(from: "KZT", to: "PYG", start_date: @day1, end_date: @day2)
  end

  test "does not remember a leg that failed because the provider is rate limiting" do
    @provider.expects(:fetch_exchange_rates).twice.returns(provider_error_response(Provider::TwelveData::RateLimitError.new("slow down")))

    2.times { assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2) }
  end

  test "remembers a miss when both USD legs have quotes but no shared dates" do
    @provider.expects(:fetch_exchange_rates).with(from: "KZT", to: "USD", start_date: @day1, end_date: @day2).once
             .returns(provider_success_response([ rate(@day1, "KZT", "USD", 0.002) ]))
    @provider.expects(:fetch_exchange_rates).with(from: "USD", to: "RUB", start_date: @day1, end_date: @day2).once
             .returns(provider_success_response([ rate(@day2, "USD", "RUB", 80) ]))

    2.times { assert_empty ExchangeRate::UsdCross.new(@provider).rates(from: "KZT", to: "RUB", start_date: @day1, end_date: @day2) }
  end

  private
    def rate(date, from, to, value)
      Provider::ExchangeRateConcept::Rate.new(date: date, from: from, to: to, rate: value)
    end
end
