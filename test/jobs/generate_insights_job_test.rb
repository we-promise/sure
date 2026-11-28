require "test_helper"
require Rails.root.join("test/support/web_push_test_helper")

class GenerateInsightsJobTest < ActiveJob::TestCase
  include WebPushTestHelper

  setup do
    @family = families(:dylan_family)
    enable_preview_features(@family)
  end

  test "without args enqueues one job per preview-enabled family" do
    assert_operator Family.count, :>, Family.with_preview_features.count,
      "fixture setup should leave some families without preview access"

    assert_enqueued_jobs Family.with_preview_features.count, only: GenerateInsightsJob do
      GenerateInsightsJob.perform_now
    end

    assert_enqueued_with(job: GenerateInsightsJob, args: [ { family_id: @family.id } ])
  end

  # Insights is a preview feature and the job manufactures data per family,
  # so families with nobody opted in are skipped entirely rather than
  # generated for and hidden.
  test "without args enqueues nothing when no family has preview access" do
    disable_preview_features(@family)

    assert_no_enqueued_jobs only: GenerateInsightsJob do
      GenerateInsightsJob.perform_now
    end
  end

  test "does nothing for a family without preview access" do
    disable_preview_features(@family)

    assert_no_difference "Insight.count" do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
  end

  test "does not broadcast for a family without preview access" do
    disable_preview_features(@family)

    Turbo::StreamsChannel.expects(:broadcast_replace_to).never

    GenerateInsightsJob.perform_now(family_id: @family.id)
  end

  test "generates for a family where only one member opted in" do
    @family.users.each { |user| set_preview_features(user, false) }
    set_preview_features(@family.users.first, true)

    stub_generated([ generated_insight ])

    assert_difference "@family.insights.count", 1 do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
  end

  test "does nothing for an unknown family" do
    assert_nothing_raised do
      GenerateInsightsJob.perform_now(family_id: SecureRandom.uuid)
    end
  end

  test "does nothing for a family without accounts" do
    family = families(:empty)

    assert_no_difference "Insight.count" do
      GenerateInsightsJob.perform_now(family_id: family.id)
    end
  end

  test "runs all generators against real family data without raising" do
    assert_nothing_raised do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
  end

  test "creates an active insight with a body from a generated insight" do
    stub_generated([ generated_insight ])

    assert_difference "@family.insights.count", 1 do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    assert_equal "active", insight.status
    assert_equal "idle_cash", insight.insight_type
    assert insight.body.present?
    assert_equal 5000.0, insight.metadata["balance"]
  end

  # The badge rides the family stream every layout subscribes to, so new unread
  # insights bump the lightbulb count on whatever page is open.
  test "broadcasts the unread badge alongside the refreshed list" do
    stub_generated([ generated_insight ])
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with(
      @family,
      targets: "[data-insights-badge]",
      partial: "layouts/shared/insights_badge",
      locals: { count: @family.insights.active.count + 1 }
    )

    GenerateInsightsJob.perform_now(family_id: @family.id)
  end

  test "broadcasts the feed in the family's locale" do
    @family.update!(locale: "de")
    stub_generated([ generated_insight ])
    locales = []
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).with { locales << I18n.locale; true }

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert_equal [ :de ], locales.uniq
  end

  test "enqueues notifications for newly created high priority insights" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    opted_in_user, opted_out_user = @family.users.to_a
    set_preview_features(opted_out_user, false)
    subscription = opted_in_user.push_subscriptions.create!(
      token: "ab" * 32,
      environment: "sandbox",
      platform: "ios",
      last_registered_at: Time.current
    )
    opted_out_user.push_subscriptions.create!(
      token: "cd" * 32,
      environment: "sandbox",
      platform: "ios",
      last_registered_at: Time.current
    )
    Apns::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])

    assert_enqueued_jobs 1, only: DeliverInsightNotificationJob do
      assert_enqueued_with(
        job: DeliverInsightNotificationJob,
        args: ->(args) {
          args.one? && args.first[:push_delivery_id].present?
        }
      ) do
        GenerateInsightsJob.perform_now(family_id: @family.id)
      end
    end
    assert_equal [ subscription.id ],
      PushDelivery.apns.where(insight: @family.insights).pluck(:subscription_id)
  end

  test "browser push uses new and materially resurfaced insights but not routine refreshes" do
    require Rails.root.join("test/support/web_push_test_helper")
    extend WebPushTestHelper
    user = @family.users.first
    register_web_push(user: user)
    WebPush::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])
    assert_enqueued_jobs 1, only: DeliverInsightNotificationJob do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
    insight = @family.insights.find_by!(dedup_key: "idle_cash:test-account:2026-07")
    original_version = insight.notification_version
    assert_no_enqueued_jobs only: DeliverInsightNotificationJob do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
    assert_equal original_version, insight.reload.notification_version
    insight.update!(status: "expired")
    assert_enqueued_jobs 1, only: DeliverInsightNotificationJob do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
    assert_equal original_version + 1, insight.reload.notification_version
  end

  test "a material metadata change increments the browser delivery version" do
    register_web_push(user: @family.users.first)
    WebPush::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    insight = @family.insights.find_by!(dedup_key: "idle_cash:test-account:2026-07")
    version = insight.notification_version
    stub_generated([ generated_insight(balance: 7500.0, priority: "high") ])
    assert_enqueued_jobs 1, only: DeliverInsightNotificationJob do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
    assert_equal version + 1, insight.reload.notification_version
    assert_equal [ version, version + 1 ], PushDelivery.where(insight: insight).order(:insight_version).pluck(:insight_version)
  end

  test "deleting a device between eligibility and delivery recording preserves the insight" do
    subscription = register_web_push(user: @family.users.first)
    WebPush::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])
    WebPushSubscription.any_instance.stubs(:eligible?).with do
      WebPushSubscription.where(id: subscription.id).delete_all
      true
    end.returns(true)
    assert_difference "Insight.count", 1 do
      assert_no_difference "PushDelivery.count" do
        GenerateInsightsJob.perform_now(family_id: @family.id)
      end
    end
  end

  test "a failed broadcast does not hold back the push and an unchanged rerun sends nothing new" do
    subscription = register_web_push(user: @family.users.first)
    WebPush::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).raises(StandardError, "Broadcast unavailable")

    assert_enqueued_jobs 1, only: DeliverInsightNotificationJob do
      assert_raises(StandardError) { GenerateInsightsJob.perform_now(family_id: @family.id) }
    end

    Turbo::StreamsChannel.stubs(:broadcast_replace_to).returns(nil)
    assert_no_enqueued_jobs only: DeliverInsightNotificationJob do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
    assert_equal 1, subscription.push_deliveries.count
  end

  test "a ledger failure rolls back a newly generated insight and its version" do
    register_web_push(user: @family.users.first)
    WebPush::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])
    PushDelivery.stubs(:for_subscription).raises(ActiveRecord::RecordInvalid.new(PushDelivery.new))

    assert_no_difference [ "Insight.count", "PushDelivery.count" ] do
      assert_no_enqueued_jobs only: DeliverInsightNotificationJob do
        GenerateInsightsJob.perform_now(family_id: @family.id)
      end
    end
  end

  test "a ledger failure rolls back a material insight change with its delivery records" do
    register_web_push(user: @family.users.first)
    WebPush::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    insight = @family.insights.find_by!(dedup_key: "idle_cash:test-account:2026-07")
    original_metadata = insight.metadata
    original_version = insight.notification_version
    stub_generated([ generated_insight(balance: 7500.0, priority: "high") ])
    PushDelivery.stubs(:for_subscription).raises(ActiveRecord::RecordInvalid.new(PushDelivery.new))

    assert_no_difference "PushDelivery.count" do
      assert_no_enqueued_jobs only: DeliverInsightNotificationJob do
        GenerateInsightsJob.perform_now(family_id: @family.id)
      end
    end
    assert_equal original_version, insight.reload.notification_version
    assert_equal original_metadata, insight.metadata
  end

  test "a device registered after an insight event receives no backlog" do
    WebPush::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    insight = @family.insights.find_by!(dedup_key: "idle_cash:test-account:2026-07")
    subscription = register_web_push(user: @family.users.first)

    assert_no_enqueued_jobs only: DeliverInsightNotificationJob do
      PushDelivery.enqueue_insight_deliveries(insight)
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
    assert_empty subscription.push_deliveries
  end

  test "budget warning opt in after an insight event receives no backlog" do
    user = @family.users.first
    subscription = register_web_push(user: user)
    WebPush::Client.stubs(:configured?).returns(true)
    generated = generated_insight(priority: "medium").with(insight_type: "budget_at_risk")
    stub_generated([ generated ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    insight = @family.insights.find_by!(dedup_key: generated.dedup_key)
    user.update!(preferences: user.preferences.merge("push_budget_warnings_enabled" => true))

    assert_no_enqueued_jobs only: DeliverInsightNotificationJob do
      PushDelivery.enqueue_insight_deliveries(insight)
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end
    assert_empty subscription.push_deliveries
  end

  test "re-running with unchanged numbers does not duplicate or rewrite" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    original_body = insight.body

    assert_no_difference "@family.insights.count" do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end

    assert_equal original_body, insight.reload.body
  end

  # The body is the i18n template filled with the facts, so it refreshes with
  # them; an unchanged metadata still means no resurfacing and no new push.
  test "refreshes display facts and the body in place when metadata is unchanged" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    assert_equal "$5000", insight.facts["balance"]
    original_body = insight.body
    insight.mark_read!

    stub_generated([ generated_insight(display_balance: 5040) ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert_equal "$5040", insight.facts["balance"]
    assert_not_equal original_body, insight.body
    assert_includes insight.body, "$5040"
    assert insight.read?
  end

  test "a body refreshed in place is not notified again" do
    user = @family.users.first
    register_web_push(user: user)
    WebPush::Client.stubs(:configured?).returns(true)
    stub_generated([ generated_insight(priority: "high") ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    original_version = insight.notification_version
    clear_enqueued_jobs

    stub_generated([ generated_insight(priority: "high", display_balance: 5040) ])
    assert_no_enqueued_jobs do
      GenerateInsightsJob.perform_now(family_id: @family.id)
    end

    insight.reload
    assert_equal original_version, insight.notification_version
    assert_equal 1, PushDelivery.count
    assert_equal "pending", PushDelivery.order(:created_at).last.reload.status
  end

  test "an expired insight that returns with new display facts gets a fresh body" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")

    stub_generated([], succeeded_types: [ "idle_cash" ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    stub_generated([ generated_insight(display_balance: 5040) ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert_includes insight.reload.body, "$5040"
  end

  # The title is built from I18n and the generator's own data, not written by
  # the model. A goal or category renamed since the insight was stored left it
  # naming something that no longer exists, for the rest of the month.
  test "a renamed subject refreshes the title without resurfacing the insight" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    original_body = insight.body
    insight.mark_read!

    stub_generated([ generated_insight(title: "Idle cash in Holiday Fund") ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert_equal "Idle cash in Holiday Fund", insight.title
    assert_equal original_body, insight.body, "a rename doesn't rewrite the body"
    assert insight.read?, "a rename is not a reason to nag the user again"
  end
  test "a reactivated insight also picks up a renamed subject" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.update!(status: "expired")

    stub_generated([ generated_insight(title: "Idle cash in Holiday Fund") ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert insight.active?
    assert_equal "Idle cash in Holiday Fund", insight.title
  end
  test "acknowledged insight stays acknowledged when numbers are unchanged" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.acknowledge!

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.acknowledged?
  end

  test "acknowledged insight reactivates when numbers change materially" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.acknowledge!

    stub_generated([ generated_insight(balance: 9000.0) ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert insight.active?
    assert_equal 9000.0, insight.metadata["balance"]
    assert_nil insight.dismissed_at
    assert_nil insight.read_at
  end

  # An aggregate carries the account set it was computed from. A share change
  # (or a row stored before the digest existed) rewrites prose that may quote
  # figures from the old set, without resurfacing what the user put away.
  test "a changed account set rewrites the body but keeps acknowledged state" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    original_body = insight.body
    insight.acknowledge!

    rescoped = generated_insight(display_balance: 3000)
    stub_generated([ rescoped.with(metadata: rescoped.metadata.merge(accounts_digest: "new-set")) ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert_not_equal original_body, insight.body
    assert_includes insight.body, "$3000"
    assert_equal "new-set", insight.metadata["accounts_digest"]
    assert insight.acknowledged?
  end

  test "adding the account an insight is about keeps acknowledged state" do
    stub_generated([ generated_insight.with(metadata: generated_insight.metadata.except(:account_id)) ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    insight.acknowledge!

    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert_equal accounts(:depository).id, insight.metadata["account_id"]
    assert insight.acknowledged?
  end

  test "expires a visible insight whose condition cleared" do
    insight = insights(:cash_flow_warning)
    stub_generated([], succeeded_types: [ "cash_flow_warning" ])

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.expired?
    assert_not_includes Insight.visible, insight
  end

  test "does not expire insights whose generator failed" do
    insight = insights(:cash_flow_warning)
    stub_generated([], succeeded_types: [])

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.active?
  end

  test "does not touch acknowledged insights when their condition clears" do
    insight = insights(:cash_flow_warning)
    insight.acknowledge!
    stub_generated([], succeeded_types: [ "cash_flow_warning" ])

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.acknowledged?
  end

  test "expired insight reactivates without a body rewrite when the condition returns unchanged" do
    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight = @family.insights.find_by(dedup_key: "idle_cash:test-account:2026-07")
    original_body = insight.body
    insight.mark_read!

    stub_generated([], succeeded_types: [ "idle_cash" ])
    GenerateInsightsJob.perform_now(family_id: @family.id)
    assert insight.reload.expired?

    stub_generated([ generated_insight ])
    GenerateInsightsJob.perform_now(family_id: @family.id)

    insight.reload
    assert insight.active?
    assert_equal original_body, insight.body
    assert_nil insight.read_at
  end

  test "expires an insight hidden because its account is no longer shared with everyone" do
    insight = @family.insights.create!(
      insight_type: "idle_cash", priority: "low", status: "active", title: "Idle", body: "body",
      metadata: { "account_id" => accounts(:connected).id }, dedup_key: "idle_cash:private",
      generated_at: Time.current
    )
    assert_not @family.insights.visible.exists?(id: insight.id), "precondition: the row must be hidden, not just stale"
    stub_generated([], succeeded_types: [ "idle_cash" ])

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert insight.reload.expired?, "a hidden row whose condition cleared must not come back stale once access returns"
  end

  private
    def enable_preview_features(family)
      family.users.each { |user| set_preview_features(user, true) }
    end

    def disable_preview_features(family)
      family.users.each { |user| set_preview_features(user, false) }
    end

    def set_preview_features(user, enabled)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => enabled))
    end

    def stub_generated(generated_insights, succeeded_types: nil)
      result = Insight::GeneratorRegistry::Result.new(
        insights: generated_insights,
        succeeded_types: succeeded_types || generated_insights.map(&:insight_type).uniq
      )
      Insight::GeneratorRegistry.any_instance.stubs(:generate_all).returns(result)
    end

    # display_balance changes only the formatted facts, leaving metadata (the
    # material-change signal) untouched — mirrors a balance drifting slightly
    # between runs without crossing a bucket boundary.
    def generated_insight(balance: 5000.0, display_balance: nil, priority: "low", title: "Idle cash in Test Checking")
      Insight::Generator::GeneratedInsight.new(
        insight_type: "idle_cash",
        priority: priority,
        title: title,
        template_key: "idle_cash",
        facts: { account: "Test Checking", balance: "$#{(display_balance || balance).to_i}", idle_days: 60 },
        metadata: { account_id: accounts(:depository).id, balance: balance },
        currency: "USD",
        period_start: nil,
        period_end: nil,
        dedup_key: "idle_cash:test-account:2026-07"
      )
    end
end
