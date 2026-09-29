require "test_helper"

class IbkrAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "IBKR Brokerage",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    @ibkr_account = @family.ibkr_items.create!(
      name: "IBKR",
      query_id: "QUERY123",
      token: "TOKEN123"
    ).ibkr_accounts.create!(
      name: "Main",
      ibkr_account_id: "U1234567",
      currency: "CHF",
      current_balance: 3351,
      cash_balance: 1000.5,
      report_date: Date.current - 1.day
    )
    @ibkr_account.ensure_account_provider!(@account)
  end

  # The NAV is as of IBKR's report date, and the holdings imported beside it
  # carry that same date. Anchored to today instead, one day's NAV is weighed
  # against the next day's prices and the cash plug absorbs the difference.
  test "anchors the balance on the statement's report date" do
    IbkrAccount::Processor.new(@ibkr_account).process

    entry = @account.valuations.current_anchor.first.entry
    assert_equal Date.current - 1.day, entry.date
    assert_equal 3351, entry.amount
  end

  # A statement that has not moved on is the same statement: it updates the
  # anchor where it stands rather than leaving a reconciliation behind it.
  test "a repeated report date does not accumulate valuations" do
    IbkrAccount::Processor.new(@ibkr_account).process

    travel_to Date.current + 1.day do
      assert_no_difference -> { @account.valuations.count } do
        IbkrAccount::Processor.new(@ibkr_account.reload).process
      end
    end

    assert_equal Date.current - 1.day, @account.valuations.current_anchor.first.entry.date
  end

  # An older statement describes a day gone by. The account's own balance, and
  # the cash split beside it, are what it is worth now, so neither follows it.
  test "an older statement leaves the account's own balance alone" do
    IbkrAccount::Processor.new(@ibkr_account).process
    assert_equal 3351, @account.reload.balance

    @ibkr_account.update!(report_date: Date.current - 3.days, current_balance: 2000, cash_balance: 40)
    IbkrAccount::Processor.new(@ibkr_account.reload).process

    @account.reload
    assert_equal 3351, @account.balance, "the cached balance must not follow an older statement"
    assert_equal 1000.5, @account.cash_balance, "nor its cash split"
    assert_equal Date.current - 1.day, @account.valuations.current_anchor.first.entry.date
    older = @account.entries.valuations.find_by(date: Date.current - 3.days)
    assert_not_nil older, "the older statement is kept where it belongs"
    assert_equal 2000, older.amount
  end

  # A failed NAV write leaves the anchor and the cached balance where they were,
  # so the cash split must stay with them rather than move on alone.
  test "a failed balance write leaves the cash split alone" do
    IbkrAccount::Processor.new(@ibkr_account).process
    assert_equal 1000.5, @account.reload.cash_balance

    Account::CurrentBalanceManager.any_instance.stubs(:set_current_balance).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "boom")
    )
    @ibkr_account.update!(cash_balance: 42)

    assert_difference -> { DebugLogEntry.where(source: "IbkrAccount::Processor", category: "provider_sync_error").count }, 1 do
      IbkrAccount::Processor.new(@ibkr_account.reload).process
    end

    assert_equal 1000.5, @account.reload.cash_balance
  end

  # The currency changes only with a balance that was actually written, so the
  # cached figures keep the denomination they were written in.
  test "an older statement or a failed write does not change the currency" do
    IbkrAccount::Processor.new(@ibkr_account).process

    @ibkr_account.update!(report_date: Date.current - 3.days, currency: "USD")
    IbkrAccount::Processor.new(@ibkr_account.reload).process
    assert_equal "CHF", @account.reload.currency, "an older statement leaves the currency alone"

    @ibkr_account.update!(report_date: Date.current)
    Account::CurrentBalanceManager.any_instance.stubs(:set_current_balance).returns(
      Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "boom")
    )
    IbkrAccount::Processor.new(@ibkr_account.reload).process
    assert_equal "CHF", @account.reload.currency, "a failed write puts the currency back"
  end

  # Nothing to date it by, or a statement dated ahead of today: fall back to
  # today rather than anchoring the account in the future.
  test "falls back to today when the report date is missing or ahead" do
    @ibkr_account.update!(report_date: nil)
    IbkrAccount::Processor.new(@ibkr_account).process
    assert_equal Date.current, @account.valuations.current_anchor.first.entry.date

    @ibkr_account.update!(report_date: Date.current + 3.days)
    IbkrAccount::Processor.new(@ibkr_account.reload).process
    assert_equal Date.current, @account.valuations.current_anchor.first.entry.date
  end
end
