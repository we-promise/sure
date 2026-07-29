require "test_helper"
require "ostruct"

class Account::SyncerTest < ActiveSupport::TestCase
  test "post-sync auto matches only transfers touching the synced account" do
    account = accounts(:depository)

    account.family.expects(:auto_match_transfers!).with(account: account).once

    Account::Syncer.new(account).perform_post_sync
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

  # Ordering is the point: accruals must exist before balances are calculated,
  # or the new entries land a sync too late. Asserted with a sequence rather than
  # bare call counts so the test actually checks what its name claims.
  test "accrues loan interest before materializing balances" do
    account = accounts(:loan)
    order = sequence("accrual precedes materialization")

    Account::MarketDataImporter.any_instance.expects(:import_all).once
    Loan::InterestAccrual.any_instance.expects(:sync!).once.returns(false).in_sequence(order)
    Balance::Materializer.any_instance.expects(:materialize_balances).once.in_sequence(order)

    Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: nil))
  end

  test "drops the incremental window when accruals changed" do
    account = accounts(:loan)
    window = 5.days.ago.to_date

    Account::MarketDataImporter.any_instance.expects(:import_all).once
    Loan::InterestAccrual.any_instance.expects(:sync!).once.returns(true)
    Balance::Materializer.expects(:new)
                         .with(account, has_entries(window_start_date: nil))
                         .returns(stub(materialize_balances: nil))

    Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: window))
  end

  test "keeps the incremental window when accruals did not change" do
    account = accounts(:loan)
    window = 5.days.ago.to_date

    Account::MarketDataImporter.any_instance.expects(:import_all).once
    Loan::InterestAccrual.any_instance.expects(:sync!).once.returns(false)
    Balance::Materializer.expects(:new)
                         .with(account, has_entries(window_start_date: window))
                         .returns(stub(materialize_balances: nil))

    Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: window))
  end

  test "an accrual failure degrades the loan rather than failing the sync" do
    account = accounts(:loan)

    Account::MarketDataImporter.any_instance.expects(:import_all).once
    Loan::InterestAccrual.any_instance.expects(:sync!).raises(StandardError, "boom")
    Balance::Materializer.any_instance.expects(:materialize_balances).once

    assert_nothing_raised do
      Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: nil))
    end
  end

  test "skips accrual entirely for non-loan accounts" do
    account = accounts(:depository)

    Account::MarketDataImporter.any_instance.expects(:import_all).once
    Loan::InterestAccrual.any_instance.expects(:sync!).never
    Balance::Materializer.any_instance.expects(:materialize_balances).once

    Account::Syncer.new(account).perform_sync(OpenStruct.new(window_start_date: nil))
  end
end
