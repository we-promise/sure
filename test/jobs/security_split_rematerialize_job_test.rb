require "test_helper"

class SecuritySplitRematerializeJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @account = families(:empty).accounts.create!(name: "Brokerage", balance: 2000, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @security = Security.create!(ticker: "SPLJ", name: "Split Job")
    @ex_date = 3.days.ago.to_date
    (@ex_date - 2..Date.current).each do |date|
      Security::Price.create!(security: @security, date: date, price: date < @ex_date ? 100 : 50, currency: "USD")
    end
    create_trade(@security, account: @account, qty: 10, price: 100, date: @ex_date - 2)
    Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")
  end

  test "the job rebuilds the security's holdings from the ex-date" do
    assert_equal [ 10, 10 ], quantities, "before the job the holdings still ignore the split"

    SecuritySplitRematerializeJob.perform_now(@account, @security)

    assert_equal [ 10, 20 ], quantities
  end

  test "an account mid-sync is retried, not materialised, until its sync finishes" do
    sync = @account.syncs.create!
    sync.update_columns(status: "syncing")

    assert_enqueued_with(job: SecuritySplitRematerializeJob) do
      SecuritySplitRematerializeJob.perform_now(@account, @security)
    end
    assert_equal [ 10, 10 ], quantities

    sync.update_columns(status: "completed")
    SecuritySplitRematerializeJob.perform_now(@account, @security)

    assert_equal [ 10, 20 ], quantities
  end

  test "a pending sync does not hold the job back" do
    @account.syncs.create!

    assert_no_enqueued_jobs(only: SecuritySplitRematerializeJob) do
      SecuritySplitRematerializeJob.perform_now(@account, @security)
    end
    assert_equal [ 10, 20 ], quantities
  end

  private
    # The share count the day before the ex-date and on it.
    def quantities
      [ @ex_date - 1, @ex_date ].map { |date| @account.holdings.find_by!(security: @security, date: date).qty.to_i }
    end
end
