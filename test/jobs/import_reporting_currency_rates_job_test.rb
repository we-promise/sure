require "test_helper"

class ImportReportingCurrencyRatesJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "imports exchange rates for each account in the family's history, disabled ones included" do
    ExchangeRate.stubs(:provider).returns(mock("provider"))
    @family.accounts.visible.first.update_columns(status: "disabled")
    historical = @family.accounts.historical.count
    assert @family.accounts.where(status: "disabled").exists?, "precondition: the family has a disabled account"

    Account::MarketDataImporter.any_instance.expects(:import_exchange_rates).times(historical)

    ImportReportingCurrencyRatesJob.perform_now(@family)
  end

  test "does nothing without an exchange rate provider" do
    ExchangeRate.stubs(:provider).returns(nil)

    Account::MarketDataImporter.any_instance.expects(:import_exchange_rates).never

    ImportReportingCurrencyRatesJob.perform_now(@family)
  end
end
