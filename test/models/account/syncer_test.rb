require "test_helper"
require "ostruct"

class Account::SyncerTest < ActiveSupport::TestCase
  test "applies IBKR historical balance overrides after materialization" do
    family = families(:empty)
    account = family.accounts.create!(
      name: "IBKR Brokerage",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    ibkr_account = family.ibkr_items.create!(
      name: "IBKR",
      query_id: "QUERY123",
      token: "TOKEN123"
    ).ibkr_accounts.create!(
      name: "Main",
      ibkr_account_id: "U1234567",
      currency: "CHF"
    )
    ibkr_account.ensure_account_provider!(account)

    Account::MarketDataImporter.any_instance.expects(:import_all).once
    Balance::Materializer.any_instance.expects(:materialize_balances).once
    IbkrAccount::HistoricalBalancesSync.any_instance.expects(:sync!).once

    Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: nil))
  end
end
