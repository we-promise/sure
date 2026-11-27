require "test_helper"

class ImportInstitutionRatesJobTest < ActiveJob::TestCase
  test "imports each account's exchange rates without syncing it" do
    Account::MarketDataImporter.any_instance.expects(:import_exchange_rates).twice

    assert_no_difference -> { Sync.count } do
      ImportInstitutionRatesJob.perform_now([ accounts(:depository).id, accounts(:credit_card).id, SecureRandom.uuid ])
    end
  end
end
