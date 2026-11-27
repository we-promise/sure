require "test_helper"

class ImportReportingCurrencyRatesJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "reads the pairs of every account in the family's history, disabled ones included" do
    ExchangeRate.stubs(:provider).returns(mock("provider"))
    @family.accounts.visible.first.update_columns(status: "disabled")
    historical = @family.accounts.historical.count
    assert @family.accounts.where(status: "disabled").exists?, "precondition: the family has a disabled account"

    Account::MarketDataImporter.any_instance.expects(:exchange_rate_pair_dates).times(historical).returns({})

    ImportReportingCurrencyRatesJob.perform_now(@family)
  end

  test "imports each pair once, from the earliest date any account needs it" do
    ExchangeRate.stubs(:provider).returns(mock("provider"))
    assert_operator @family.accounts.historical.count, :>=, 2, "precondition: accounts that share a pair"
    later = 1.month.ago.to_date
    earlier = 3.months.ago.to_date
    gbp = 2.months.ago.to_date
    Account::MarketDataImporter.any_instance.stubs(:exchange_rate_pair_dates)
      .returns({ %w[EUR USD] => later })
      .then.returns({ %w[EUR USD] => earlier, %w[GBP USD] => gbp })

    ExchangeRate.expects(:import_provider_rates).with(from: "EUR", to: "USD", start_date: earlier, end_date: Date.current).once
    ExchangeRate.expects(:import_provider_rates).with(from: "GBP", to: "USD", start_date: gbp, end_date: Date.current).once

    ImportReportingCurrencyRatesJob.perform_now(@family)
  end

  test "does nothing without an exchange rate provider" do
    ExchangeRate.stubs(:provider).returns(nil)

    Account::MarketDataImporter.any_instance.expects(:exchange_rate_pair_dates).never
    ExchangeRate.expects(:import_provider_rates).never

    ImportReportingCurrencyRatesJob.perform_now(@family)
  end
end
