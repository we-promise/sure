require "test_helper"

class ExchangeRateImportJobTest < ActiveJob::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock
    ExchangeRate.stubs(:provider).returns(@provider)
  end

  test "imports exchange rates for a single pair" do
    ExchangeRate.delete_all

    @provider.expects(:fetch_exchange_rates)
             .returns(provider_success_response([
               OpenStruct.new(from: "USD", to: "EUR", date: Date.current, rate: 0.85)
             ]))

    ExchangeRateImportJob.perform_now(
      from: "USD",
      to: "EUR",
      start_date: Date.current,
      end_date: Date.current
    )

    assert ExchangeRate.find_by(from_currency: "USD", to_currency: "EUR", date: Date.current)
  end

  test "schedules retry on rate limit error" do
    ExchangeRate.delete_all

    rate_limit_error = Provider::TwelveData::RateLimitError.new("Rate limit exceeded")

    @provider.expects(:fetch_exchange_rates)
             .returns(provider_error_response(rate_limit_error))

    assert_enqueued_with(job: ExchangeRateImportJob) do
      ExchangeRateImportJob.perform_now(
        from: "USD",
        to: "EUR",
        start_date: Date.current,
        end_date: Date.current
      )
    end
  end
end
