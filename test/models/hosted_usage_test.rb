require "test_helper"

class HostedUsageTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    travel_to Time.zone.local(2026, 10, 1, 12)
    # Existing fixtures should not look like newly recorded trials in this test.
    Subscription.update_all(created_at: 60.days.ago)
  end

  teardown do
    travel_back
  end

  test "availability requires the exact trusted deployment and matching request host" do
    %w[app.sure.am demo.sure.am].each do |host|
      with_env_overrides("APP_DOMAIN" => host) do
        assert HostedUsage.available?(request_host: host)
        refute HostedUsage.available?(request_host: "sure-app.onrender.com")
        refute HostedUsage.available?(request_host: "#{host}.example.com")
        refute HostedUsage.available?(request_host: "#{host}.")
      end
    end

    [ nil, "", "sure-app.onrender.com", "example.com", "https://app.sure.am",
      "app.sure.am:443", "*.sure.am", "APP.SURE.AM", " app.sure.am" ].each do |configured|
      with_env_overrides("APP_DOMAIN" => configured) do
        refute HostedUsage.available?(request_host: "app.sure.am"), configured.inspect
        refute HostedUsage.available?(request_host: "demo.sure.am"), configured.inspect
      end
    end
    with_env_overrides("APP_DOMAIN" => "app.sure.am") do
      refute HostedUsage.available?(request_host: "demo.sure.am")
    end
  end

  test "recent trial records include window boundaries and converted trials without claiming people" do
    lower = trial_family(created_at: 30.days.ago)
    current = trial_family(created_at: Time.current)
    converted = trial_family(created_at: 3.days.ago, status: "active", stripe_id: "sub_Converted")
    trial_family(created_at: 30.days.ago - 1.second)
    trial_family(created_at: Time.current + 1.second)
    Family.create!.create_subscription!(status: "active", stripe_id: "sub_NoTrial", created_at: 2.days.ago)
    create_user(lower)
    create_user(lower)
    create_user(current)
    create_user(converted)

    usage = HostedUsage.new

    assert_equal 3, usage.summary.fetch(:trial_households_count)
    assert_equal 4, usage.summary.fetch(:trial_members_count)
    assert_equal [ lower.id, current.id, converted.id ].sort, usage.trials.map(&:family_id).sort
    assert_equal "active", usage.trials.find { |row| row.family_id == converted.id }.status
    assert_equal 30.days.ago, usage.window_start
    assert_equal Time.current, usage.as_of
  end

  test "sessions are retained rows for enabled members with a separate creation window" do
    family = trial_family
    enabled = create_user(family)
    disabled = create_user(family)
    disabled.update_column(:active, false)
    enabled.sessions.create!(created_at: 40.days.ago)
    enabled.sessions.create!(created_at: 30.days.ago)
    enabled.sessions.create!(created_at: Time.current)
    disabled.sessions.create!(created_at: 1.day.ago)
    removed = enabled.sessions.create!(created_at: 2.days.ago)
    removed.destroy!

    row = HostedUsage.new.trials.find { |trial| trial.family_id == family.id }

    assert_equal 2, row.member_count
    assert_equal 3, row.retained_sessions_count
    assert_equal 2, row.sessions_created_in_window_count
    assert_equal Time.current, row.latest_session_created_at
  end

  test "cleanup matches the existing scope including strict grace boundaries" do
    expired = trial_family(trial_ends_at: 14.days.ago - 1.second, status: "paused")
    boundary = trial_family(trial_ends_at: 14.days.ago, status: "paused")
    old_empty = Family.create!(created_at: 59.days.ago - 1.second)
    boundary_empty = Family.create!(created_at: 59.days.ago)
    active = trial_family(trial_ends_at: 30.days.ago, status: "active", stripe_id: "sub_Active")
    # Recent login does not remove a family from the application's actual scope.
    create_user(expired).sessions.create!

    usage = HostedUsage.new
    candidates = usage.cleanup_candidates.index_by(&:family_id)

    assert_equal Family.inactive_trial_for_cleanup.count, usage.summary.fetch(:cleanup_eligible_count)
    assert_equal :expired_trial_grace_elapsed, candidates.fetch(expired.id).reason
    assert_equal :no_subscription_grace_elapsed, candidates.fetch(old_empty.id).reason
    refute candidates.key?(boundary.id)
    refute candidates.key?(boundary_empty.id)
    refute candidates.key?(active.id)
    assert usage.trials.find { |row| row.family_id == expired.id }.cleanup_eligible
    with_self_hosting { refute usage.cleanup_enabled? }
  end

  test "supporters require both Stripe-shaped links and preserve every local status" do
    active = trial_family(status: "active", stripe_id: "sub_ActiveSupport")
    active.update!(stripe_customer_id: "cus_ActiveSupport")
    canceled = trial_family(status: "canceled", stripe_id: "sub_CanceledSupport")
    canceled.update!(stripe_customer_id: "cus_CanceledSupport")
    trial_family(status: "active", stripe_id: "sub_MissingCustomer")
    demo = trial_family(status: "active", stripe_id: "sub_demo_123")
    demo.update!(stripe_customer_id: "cus_Demo")
    trial_family

    usage = HostedUsage.new

    assert_equal 1, usage.summary.fetch(:active_supporter_households_count)
    assert_equal 2, usage.summary.fetch(:supporter_subscription_count)
    assert_equal 1, usage.supporter_status_counts.fetch("active")
    assert_equal 1, usage.supporter_status_counts.fetch("canceled")
    assert_equal 0, usage.supporter_status_counts.fetch("past_due")
    assert usage.trials.find { |row| row.family_id == demo.id }.synthetic_demo
  end

  test "expiring soon matches the indicator moved from Users admin" do
    baseline = Subscription.where(status: :trialing).where(trial_ends_at: Time.current..7.days.from_now).count
    trial_family(trial_ends_at: Time.current)
    trial_family(trial_ends_at: 7.days.from_now)
    trial_family(trial_ends_at: 7.days.from_now + 1.second)
    trial_family(trial_ends_at: 1.second.ago)
    trial_family(trial_ends_at: 1.day.from_now, status: "paused")

    usage = HostedUsage.new

    assert_equal baseline + 2, usage.summary.fetch(:trials_expiring_soon_count)
    assert_equal 7.days.from_now, usage.expiring_window_end
  end

  test "detail is bounded while summary includes all recent trials" do
    3.times { trial_family }
    usage = HostedUsage.new
    usage.stubs(:row_limit).returns(2)

    assert_equal 3, usage.summary.fetch(:trial_households_count)
    assert_equal 2, usage.trials.length
  end

  test "empty trial cohorts have empty detail and zero member counts" do
    usage = HostedUsage.new

    assert_equal 0, usage.summary.fetch(:trial_households_count)
    assert_equal 0, usage.summary.fetch(:trial_members_count)
    assert_empty usage.trials
  end

  test "all supported local Stripe statuses remain visible" do
    Subscription.statuses.each_key do |status|
      family = trial_family(status:, stripe_id: "sub_Status#{status.delete('_')}")
      family.update!(stripe_customer_id: "cus_Status#{status.delete('_')}")
    end

    assert_equal Subscription.statuses.keys.index_with(1), HostedUsage.new.supporter_status_counts
  end

  test "cleanup detail is independently bounded while its count uses the full scope" do
    3.times { Family.create!(created_at: 60.days.ago) }
    usage = HostedUsage.new
    usage.stubs(:row_limit).returns(2)

    assert_equal Family.inactive_trial_for_cleanup.count, usage.summary.fetch(:cleanup_eligible_count)
    assert_operator usage.summary.fetch(:cleanup_eligible_count), :>=, 3
    assert_equal 2, usage.cleanup_candidates.length
  end

  test "snapshot uses bounded grouped queries and performs no writes or provider calls" do
    3.times { create_user(trial_family).sessions.create! }
    Provider::Registry.expects(:get_provider).never
    DestroyJob.expects(:perform_later).never
    InactiveFamilyCleanerJob.expects(:perform_later).never

    usage = HostedUsage.new
    queries = capture_sql_queries do
      assert_no_enqueued_jobs do
        usage.summary
        usage.trials
        usage.cleanup_candidates
        usage.supporter_status_counts
      end
    end

    assert queries.all? { |query| query.start_with?("SELECT") }, queries.join("\n")
    assert_operator queries.length, :<=, 14
    assert_empty capture_sql_queries { usage.summary; usage.trials; usage.cleanup_candidates; usage.supporter_status_counts }
  end

  private
    def trial_family(created_at: 1.day.ago, trial_ends_at: 44.days.from_now, status: "trialing", stripe_id: nil)
      family = Family.create!(name: "Usage test", created_at: created_at)
      family.create_subscription!(created_at:, trial_ends_at:, status:, stripe_id:)
      family
    end

    def create_user(family)
      User.create!(family:, email: "usage-#{SecureRandom.uuid}@example.com", password: "testpassword123", role: :admin)
    end
end
