require "test_helper"
require "ostruct"

class Account::SyncerTest < ActiveSupport::TestCase
  test "post-sync auto matches only transfers touching the synced account" do
    account = accounts(:depository)

    account.family.expects(:auto_match_transfers!).with(account: account).once

    Account::Syncer.new(account).perform_post_sync
  end

  test "preloads account providers once for the full sync" do
    account = accounts(:depository)
    AccountProvider.create!(account: account, provider: plaid_accounts(:one))
    Account::MarketDataImporter.any_instance.stubs(:import_all)
    Balance::Materializer.any_instance.stubs(:materialize_balances)

    queries = capture_sql_queries do
      Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: nil))
    end

    provider_queries = queries.grep(/FROM "account_providers"/)
    assert_equal 1, provider_queries.size, provider_queries.join("\n")
  end

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
