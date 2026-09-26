require "test_helper"

# Regression cover for balance history on Akahu accounts.
#
# A previous attempt at per-fund visibility imported holdings that only existed
# for the current day. The reverse balance calculator derives each past day's
# non-cash value from the holdings priced on that date, so every historical
# balance collapsed to zero while today's row still looked correct. Asserting
# only on "today" missed it entirely.
#
# These tests therefore run a sync across multiple days and assert on the whole
# series: earlier days must keep their own values.
class AkahuAccount::BalanceHistoryTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @family = families(:empty)
    @akahu_item = AkahuItem.create!(
      family: @family,
      name: "Test Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
    @akahu_account = AkahuAccount.create!(
      akahu_item: @akahu_item,
      name: "Kernel Wealth - Global 100",
      account_id: "acc_kernel::143705",
      currency: "NZD",
      current_balance: 100_000,
      institution_metadata: { "name" => "Kernel Wealth" }
    )
    @account = Account.create!(
      family: @family,
      name: "Kernel Wealth - Global 100",
      accountable: Investment.new,
      balance: 100_000,
      cash_balance: 0,
      currency: "NZD"
    )
    AccountProvider.create!(account: @account, provider: @akahu_account)
  end

  test "each day's balance is retained as the account is synced over time" do
    day_one = Date.current - 2
    day_two = Date.current - 1
    today = Date.current

    sync_on(day_one, balance: 100_000)
    sync_on(day_two, balance: 101_500)
    sync_on(today, balance: 99_750)

    assert_equal BigDecimal("100000"), balance_on(day_one)
    assert_equal BigDecimal("101500"), balance_on(day_two)
    assert_equal BigDecimal("99750"), balance_on(today)
  end

  test "history is never collapsed to zero by a sync" do
    sync_on(Date.current - 1, balance: 100_000)
    sync_on(Date.current, balance: 100_000)

    balances = @account.balances.where(currency: "NZD").order(:date)

    assert balances.any?, "expected a materialized balance series"
    assert_equal 0, balances.where(balance: 0).count,
      "a sync must never zero out previously known balances"
  end

  test "synthetic fund accounts keep history and report provider returns as gains" do
    day_one = Date.current - 2
    day_two = Date.current - 1
    today = Date.current

    sync_on(day_one, balance: 100_000, returns: 5_000)
    sync_on(day_two, balance: 101_500, returns: 6_500)
    sync_on(today,   balance: 99_750,  returns: 4_200)

    assert_equal BigDecimal("100000"), balance_on(day_one)
    assert_equal BigDecimal("101500"), balance_on(day_two)
    assert_equal BigDecimal("99750"),  balance_on(today)
    assert_equal 0, Balance.where(account_id: @account.id, balance: 0).count

    holding = Holding.where(account_id: @account.id).order(:date).last
    assert_equal BigDecimal("1"), holding.qty
    assert_equal BigDecimal("99750"), holding.amount
    assert_equal BigDecimal("95550"), holding.cost_basis
    assert_equal BigDecimal("4200"), holding.amount - (holding.cost_basis * holding.qty)
  end

  test "past values survive a later sync that does not change the balance" do
    day_one = Date.current - 1

    sync_on(day_one, balance: 100_000)
    assert_equal BigDecimal("100000"), balance_on(day_one)

    sync_on(Date.current, balance: 100_000)

    assert_equal BigDecimal("100000"), balance_on(day_one),
      "re-syncing must not rewrite or drop the earlier day's balance"
  end

  private

    # Runs the provider processor as it would run on the given day, then
    # materializes balances the way Account::Syncer does for linked accounts.
    def sync_on(date, balance:, returns: nil)
      travel_to date.to_time(:utc).change(hour: 12) do
        attrs = { current_balance: balance }
        if returns
          attrs[:raw_payload] = {
            "_id" => @akahu_account.account_id,
            "meta" => {
              "portfolio" => [ {
                "name" => "Global 100",
                "value" => balance,
                "returns" => returns,
                "fund_id" => "143705",
                "currency" => "NZD"
              } ]
            }
          }
        end
        @akahu_account.update!(attrs)
        # Reload both records each run. A long-lived Account instance memoizes
        # its CurrentBalanceManager (and with it the current anchor), which a
        # real sync never does: each job loads the account fresh.
        AkahuAccount::Processor.new(AkahuAccount.find(@akahu_account.id)).process
        Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
      end
    end

    def balance_on(date)
      Balance.find_by(account_id: @account.id, date: date, currency: "NZD")&.balance
    end
end
