require "test_helper"

class EnableBankingItem::SyncSchedulingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @item = EnableBankingItem.create!(family: families(:dylan_family), name: "Bank", country_code: "IT",
                                    application_id: "app", client_certificate: "cert", session_id: "session",
                                    session_expires_at: 1.day.from_now)
  end

  test "a persisted cooldown blocks duplicate requests and worker reservations" do
    sync = @item.sync_later
    assert @item.reserve_sync_slot!(sync: sync)
    another_instance = EnableBankingItem.find(@item.id)
    assert_no_enqueued_jobs { assert_nil another_instance.sync_later }
    assert_not another_instance.reserve_sync_slot!(sync: sync)
    travel 16.minutes do
      assert_enqueued_with(job: SyncJob) { another_instance.sync_later }
    end
  end

  test "rate limits schedule a durable retry and respect a longer Retry-After" do
    error = Provider::EnableBanking::EnableBankingError.new("limited", :rate_limited, retry_after: 9.hours, http_status: 429)
    assert_enqueued_with(job: EnableBankingSyncRetryJob) { @item.schedule_sync_retry!(error) }
    assert_in_delta 9.hours.from_now, @item.reload.next_sync_at, 2
    assert @item.sync_retry_pending?
    assert @item.session_valid?
    assert_equal 1, @item.sync_retry_count
  end

  test "fallback delays increase and obsolete retry jobs do nothing" do
    error = Provider::EnableBanking::EnableBankingError.new("limited", :rate_limited)
    @item.schedule_sync_retry!(error)
    old_retry_at = @item.next_sync_at.iso8601(6)
    assert_in_delta 6.hours.from_now, @item.next_sync_at, 2
    @item.schedule_sync_retry!(error)
    assert_in_delta 12.hours.from_now, @item.next_sync_at, 2
    assert_no_enqueued_jobs { EnableBankingSyncRetryJob.perform_now(@item, old_retry_at) }
  end

  test "retry job queues one sync when due and ignores a removed connection" do
    @item.update!(next_sync_at: 1.second.ago, sync_retry_reason: "rate_limited")
    assert_enqueued_with(job: SyncJob) do
      EnableBankingSyncRetryJob.perform_now(@item, @item.next_sync_at.iso8601(6))
    end
    @item.update!(scheduled_for_deletion: true)
    assert_no_enqueued_jobs { EnableBankingSyncRetryJob.perform_now(@item, @item.next_sync_at.iso8601(6)) }
  end

  test "temporary errors have bounded retries and an interrupted retry remains recoverable" do
    error = Provider::EnableBanking::EnableBankingError.new("timeout", :timeout)
    3.times { assert @item.schedule_sync_retry!(error) }
    assert_no_enqueued_jobs { assert_not @item.schedule_sync_retry!(error) }
    assert_not @item.sync_retry_pending?
    @item.update!(next_sync_at: 1.second.ago, sync_retry_reason: "temporary_error")
    sync = @item.sync_later
    assert @item.reserve_sync_slot!(sync: sync)
    assert @item.reload.sync_retry_pending?
    travel 16.minutes do
      assert_enqueued_with(job: SyncJob) { SyncHourlyJob.perform_now }
    end
  end

  test "the existing hourly sweep recovers retry intent after an enqueue failure" do
    configured_job = mock("retry queue")
    configured_job.expects(:perform_later).raises(ActiveJob::EnqueueError.new("unavailable"))
    EnableBankingSyncRetryJob.expects(:set).returns(configured_job)
    error = Provider::EnableBanking::EnableBankingError.new("limited", :rate_limited)
    assert @item.schedule_sync_retry!(error)
    assert @item.reload.sync_retry_pending?

    travel 7.hours do
      assert_enqueued_with(job: SyncJob) { SyncHourlyJob.perform_now }
    end
  end

  test "an early retry job is rescheduled without making a bank request" do
    @item.update!(next_sync_at: 1.minute.from_now, sync_retry_reason: "rate_limited")
    assert_enqueued_with(job: EnableBankingSyncRetryJob, at: @item.sync_retry_at) do
      EnableBankingSyncRetryJob.perform_now(@item, @item.next_sync_at.iso8601(6))
    end
  end

  test "bank siblings share background cadence and a hard rate limit across reconnection" do
    @item.update!(aspsp_name: "Test Bank")
    budget = @item.enable_banking_sync_budget
    sibling = EnableBankingItem.create!(family: @item.family, name: "Second", country_code: "IT",
      application_id: "app", client_certificate: "cert", session_id: "second", aspsp_name: "Test Bank")
    background_at = 3.hours.from_now
    hard_limit_at = 5.hours.from_now
    budget.update!(next_background_sync_at: background_at, rate_limited_until: hard_limit_at)

    assert_equal background_at.to_i, sibling.next_background_sync_at.to_i
    assert sibling.sync_rate_limited?
    assert_equal hard_limit_at.to_i, sibling.sync_rate_limited_until.to_i
    assert_nil sibling.sync_later

    @item.update!(next_sync_at: hard_limit_at, sync_retry_reason: "rate_limited")
    @item.destroy!
    replacement = EnableBankingItem.create!(family: families(:dylan_family), name: "Reconnected", country_code: "IT",
      application_id: "app", client_certificate: "cert", session_id: "third", aspsp_name: "Test Bank")
    assert replacement.sync_rate_limited?
    assert_equal hard_limit_at.to_i, replacement.sync_rate_limited_until.to_i
  end

  test "deleting an unbudgeted consent persists its legacy hard deadline" do
    @item.update!(aspsp_name: "Legacy Bank", next_sync_at: 4.hours.from_now, sync_retry_reason: "rate_limited")
    budget_scope = EnableBankingSyncBudget.where(family_id: @item.family_id, bank_key: @item.sync_budget_key)
    assert_nil budget_scope.first

    deadline = @item.next_sync_at
    @item.destroy!
    replacement = EnableBankingItem.create!(family: families(:dylan_family), name: "Reconnected", country_code: "IT",
      application_id: "app", client_certificate: "cert", session_id: "new", aspsp_name: "Legacy Bank")

    assert replacement.sync_rate_limited?
    assert_equal deadline.to_i, replacement.sync_rate_limited_until.to_i
  end

  test "reauthorization preserves a cooldown written while the provider request was in flight" do
    @item.update!(aspsp_name: "Test Bank")
    deadline = 1.hour.from_now
    EnableBankingItem.where(id: @item.id).update_all(next_sync_at: deadline, sync_retry_reason: "rate_limited")
    provider = mock("Enable Banking provider")
    provider.expects(:create_session).with(code: "code").returns(session_id: "new-session", accounts: [])
    @item.stubs(:enable_banking_provider).returns(provider)
    @item.stubs(:import_accounts_from_session)

    @item.complete_authorization(code: "code")

    assert_equal deadline.to_i, @item.reload.next_sync_at.to_i
    assert @item.sync_rate_limited?
  end

  test "a queued online context changed after consumption cannot bypass the bank cycle" do
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    @item.update!(aspsp_name: "Test Bank", aspsp_required_psu_headers: [ "PSU-IP-Address", "PSU-User-Agent" ])
    user = users(:family_admin)
    session = user.sessions.create!
    context = @item.interactive_psu_context(ip_address: "192.0.2.10", user_agent: "Sure test", user: user, session: session)
    sync = @item.sync_later(psu_context: context)
    assert sync
    provider_account = @item.enable_banking_accounts.create!(
      name: "Checking", uid: "linked", account_id: SecureRandom.uuid, currency: "EUR",
      current_balance: 100, account_status: "active", provider: "enable_banking"
    )
    account = Account.create!(family: @item.family, name: "Checking", currency: "EUR", balance: 100,
      cash_balance: 100, accountable: Depository.create!(subtype: "checking"))
    AccountProvider.create!(account: account, provider: provider_account)

    @item.enable_banking_sync_budget.update!(next_background_sync_at: 3.hours.from_now)
    stale_item = EnableBankingItem.find(@item.id)
    stale_item.expects(:import_latest_enable_banking_data).never
    consume_context = stale_item.method(:consume_psu_context!)
    stale_item.define_singleton_method(:consume_psu_context!) do |sync_record|
      context_payload = consume_context.call(sync_record)
      self.class.where(id: id).update_all(
        session_id: "rotated-consent",
        aspsp_required_psu_headers: [ "PSU-ID" ]
      )
      context_payload
    end

    stale_item.perform_sync(sync)

    assert_equal true, sync.reload.sync_stats["deferred"]
    assert_nil sync.data&.fetch("enable_banking_context", nil)
    assert_nil stale_item.reload.next_sync_at
  end

  test "stale and incomplete interactive contexts cannot bypass a future bank cycle" do
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    @item.update!(aspsp_name: "Test Bank", aspsp_required_psu_headers: [ "PSU-IP-Address", "PSU-ID" ])
    user = users(:family_admin)
    session = user.sessions.create!
    context = @item.interactive_psu_context(ip_address: "192.0.2.10", user_agent: "Sure test", user: user, session: session)
    @item.enable_banking_sync_budget.update!(next_background_sync_at: 3.hours.from_now)

    assert_empty @item.build_psu_headers(psu_context: context)
    assert_no_enqueued_jobs { assert_nil @item.sync_later(psu_context: context) }
    travel 3.minutes do
      assert_no_enqueued_jobs { assert_nil @item.sync_later(psu_context: context) }
    end
  end

  test "manual sync can bypass normal bank cadence after the item floor" do
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    @item.update!(aspsp_name: "Test Bank")
    user = users(:family_admin)
    session = user.sessions.create!
    @item.enable_banking_sync_budget.update!(next_background_sync_at: 3.hours.from_now)

    assert_nil @item.sync_later
    travel 16.minutes do
      context = @item.interactive_psu_context(ip_address: "192.0.2.10", user_agent: "Sure test", user: user, session: session)
      assert_enqueued_with(job: SyncJob) { assert @item.sync_later(psu_context: context) }
    end
  end

  test "interactive context is encrypted in Sync data and consumed only once" do
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    @item.update!(aspsp_name: "Test Bank", aspsp_required_psu_headers: [ "PSU-IP-Address", "PSU-User-Agent" ])
    user = users(:family_admin)
    session = user.sessions.create!
    context = @item.interactive_psu_context(ip_address: "192.0.2.10", user_agent: "Sure private agent", user: user, session: session)
    sync = @item.sync_later(psu_context: context)

    assert sync
    stored_data = ActiveRecord::Base.connection.select_value(
      "SELECT data::text FROM syncs WHERE id = #{ActiveRecord::Base.connection.quote(sync.id)}"
    )
    refute_includes stored_data, "192.0.2.10"
    refute_includes stored_data, "Sure private agent"
    assert_equal "192.0.2.10", @item.consume_psu_context!(sync).fetch("ip_address")
    assert_nil @item.consume_psu_context!(sync)
  end
end
