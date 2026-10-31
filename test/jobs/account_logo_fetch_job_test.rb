require "test_helper"

class AccountLogoFetchJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:depository)
    @account.update_columns(institution_domain: "tbank.ru")
  end

  test "paces fetches queued together" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    travel_to Time.zone.at(1_800_000_000) do
      3.times { AccountLogoFetchJob.perform_paced(@account) }

      assert_equal [ 0, 20, 40 ], enqueued_waits
    end
  end

  test "keeps pacing after a minute while earlier slots are still pending" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    travel_to Time.zone.at(1_800_000_000)
    10.times { AccountLogoFetchJob.perform_paced(@account) }
    clear_enqueued_jobs

    travel 90.seconds
    AccountLogoFetchJob.perform_paced(@account)

    assert_equal [ 110 ], enqueued_waits
  end

  test "does not reuse a slot claimed by another worker" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)

    travel_to Time.zone.at(1_800_000_000) do
      cache.write("#{AccountLogoFetchJob::PACE_KEY}:#{1_800_000_000 / 20}", true)
      AccountLogoFetchJob.perform_paced(@account)

      assert_equal [ 20 ], enqueued_waits
    end
  end

  test "fetches at once after a bounded number of probes when the cache refuses every claim" do
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.expects(:write).times(AccountLogoFetchJob::MAX_SLOT_PROBES).returns(false)
    Rails.stubs(:cache).returns(cache)

    travel_to Time.zone.at(1_800_000_000) do
      AccountLogoFetchJob.perform_paced(@account)

      assert_equal [ 0 ], enqueued_waits
    end
  end

  test "picks a logo automatically" do
    Account::LogoFetcher.any_instance.expects(:fetch).with(auto: true).returns(true)

    AccountLogoFetchJob.perform_now(@account)
  end

  test "drops the old domain's automatic icon when nothing is found for the new one" do
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "sberbank.ru.png",
                         metadata: { "logo_source" => "google", "logo_key" => "google", "logo_auto" => true })
    Account::LogoFetcher.any_instance.expects(:fetch).returns(false)

    AccountLogoFetchJob.perform_now(@account)

    assert_not @account.reload.logo.attached?
  end

  test "keeps the old automatic icon when Brandfetch was chosen during the search" do
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "sberbank.ru.png",
                         metadata: { "logo_source" => "google", "logo_key" => "google", "logo_auto" => true })
    Account::LogoFetcher.any_instance.stubs(:fetch).with do
      Account.find(@account.id).update!(logo_selection: "brandfetch")
      true
    end.returns(false)

    AccountLogoFetchJob.perform_now(@account)

    assert @account.reload.logo.attached?
  end

  test "keeps the automatic icon of the same domain when a refetch finds nothing" do
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "tbank.ru.png",
                         metadata: { "logo_source" => "google", "logo_key" => "google", "logo_auto" => true })
    Account::LogoFetcher.any_instance.expects(:fetch).returns(false)

    AccountLogoFetchJob.perform_now(@account)

    assert @account.reload.logo.attached?
  end

  test "leaves a logo the user uploaded" do
    @account.logo.attach(io: file_fixture("square-placeholder.png").open, filename: "mine.png")
    Account::LogoFetcher.any_instance.expects(:fetch).never

    AccountLogoFetchJob.perform_now(@account)
  end

  private
    def enqueued_waits
      enqueued_jobs.map { |job| ((job[:at] || Time.current.to_f) - Time.current.to_f).round }
    end
end
