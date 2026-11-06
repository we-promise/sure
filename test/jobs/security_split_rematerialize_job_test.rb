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

  # retry_on's block runs only once the attempts are spent, so a retry while the
  # sync is still running defers again rather than materialising mid-sync.
  # retry_on counts attempts per exception, in exception_executions.
  test "a retry while the sync is still running defers again, and the last attempt materialises" do
    @account.syncs.create!.update_columns(status: "syncing")

    retry_job = SecuritySplitRematerializeJob.new(@account, @security)
    retry_job.exception_executions = { "[SecuritySplitRematerializeJob::SyncInProgress]" => 5 }
    assert_enqueued_with(job: SecuritySplitRematerializeJob) { retry_job.perform_now }
    assert_equal [ 10, 10 ], quantities, "attempt 6 of 20 must not materialise while the sync runs"

    last_job = SecuritySplitRematerializeJob.new(@account, @security)
    last_job.exception_executions = { "[SecuritySplitRematerializeJob::SyncInProgress]" => 19 }
    assert_no_enqueued_jobs(only: SecuritySplitRematerializeJob) { last_job.perform_now }
    assert_equal [ 10, 20 ], quantities, "with the attempts spent the account is materialised anyway"
  end

  # A cancel request does not stop a sync that has started: it finishes its
  # work, and would overwrite holdings rebuilt underneath it.
  test "a running sync asked to cancel still holds the job back" do
    @account.syncs.create!.update_columns(status: "syncing", cancel_requested_at: Time.current)

    assert_enqueued_with(job: SecuritySplitRematerializeJob) do
      SecuritySplitRematerializeJob.perform_now(@account, @security)
    end
    assert_equal [ 10, 10 ], quantities
  end

  # A split is a fact about the security, so the write that enqueues these
  # runs in whichever family's zone made it. Each account's holdings are
  # dated by its own family's "today".
  test "the job materialises in the account's family time zone, not the enqueuer's" do
    @account.family.update!(timezone: "Pacific/Auckland")
    zones = []
    Balance::Materializer.any_instance.stubs(:materialize_balances).with { zones << Time.zone.name }

    Time.use_zone("UTC") { SecuritySplitRematerializeJob.perform_now(@account, @security) }

    assert_equal [ "Pacific/Auckland" ], zones
  end

  # Not UTC: the app's default zone is UTC, so a lost fallback would pass there.
  test "an unknown family zone falls back to the enqueuer's" do
    @account.family.update_column(:timezone, "Mars/Olympus_Mons")
    zones = []
    Balance::Materializer.any_instance.stubs(:materialize_balances).with { zones << Time.zone.name }

    Time.use_zone("Asia/Tokyo") { SecuritySplitRematerializeJob.perform_now(@account, @security) }

    assert_equal [ "Asia/Tokyo" ], zones
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
