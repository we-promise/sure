require "test_helper"

class AccountLogoBackfillJobTest < ActiveJob::TestCase
  test "queues a fetch for visible accounts with a domain and no logo" do
    Account.update_all(institution_domain: nil)
    without_logo = accounts(:depository)
    without_logo.update_columns(institution_domain: "tbank.ru")
    with_logo = accounts(:credit_card)
    with_logo.update_columns(institution_domain: "sberbank.ru")
    with_logo.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "mine.png")

    AccountLogoBackfillJob.perform_now

    assert_enqueued_jobs 1, only: AccountLogoFetchJob
    assert_enqueued_with(job: AccountLogoFetchJob, args: [ without_logo ])
  end

  test "queues a bounded batch per run and continues from where it stopped" do
    Account.update_all(institution_domain: nil)
    first, second = [ accounts(:depository), accounts(:credit_card) ].sort_by(&:id)
    [ first, second ].each { |account| account.update_columns(institution_domain: "tbank.ru") }
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)

    AccountLogoBackfillJob.perform_now(batch_size: 1)
    assert_enqueued_with(job: AccountLogoFetchJob, args: [ first ])
    clear_enqueued_jobs

    AccountLogoBackfillJob.perform_now(batch_size: 1)
    assert_enqueued_jobs 1, only: AccountLogoFetchJob
    assert_enqueued_with(job: AccountLogoFetchJob, args: [ second ])
    clear_enqueued_jobs

    AccountLogoBackfillJob.perform_now(batch_size: 1)
    # Starts over after the last batch.
    assert_enqueued_with(job: AccountLogoFetchJob, args: [ first ])
  end
end
