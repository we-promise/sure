require "test_helper"

class DeliverInsightNotificationJobTest < ActiveJob::TestCase
  setup do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Apns::Client.stubs(:configured?).returns(true)
    @insight = insights(:cash_flow_warning)
    @user = @insight.family.users.first
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @subscription = @user.push_subscriptions.create!(
      token: "ab" * 32,
      environment: "sandbox",
      platform: "ios",
      last_registered_at: Time.current
    )
  end

  test "records one ledger row per subscription and replays never duplicate it" do
    2.times { PushDelivery.record_for_insight!(@insight) }
    assert_equal 1, PushDelivery.apns.where(subscription: @subscription, insight: @insight).count
  end

  test "a material version records a fresh row without replaying the old one" do
    first = record_delivery
    @insight.increment!(:notification_version)
    PushDelivery.record_for_insight!(@insight.reload)
    assert_equal 2, PushDelivery.apns.where(insight: @insight).count

    Apns::Client.expects(:new).never
    DeliverInsightNotificationJob.perform_now(push_delivery_id: first.id)
    assert_equal "skipped", first.reload.status
  end

  test "records rows for opted-in users with recent devices only" do
    opted_out = @insight.family.users.where.not(id: @user.id).first
    opted_out.update!(preferences: opted_out.preferences.merge("preview_features_enabled" => false))
    opted_out.push_subscriptions.create!(
      token: "cd" * 32, environment: "sandbox", platform: "ios", last_registered_at: Time.current
    )
    stale = PushSubscription.create!(
      user: @user, token: "ef" * 32, environment: "sandbox", platform: "ios",
      last_registered_at: 91.days.ago
    )

    PushDelivery.record_for_insight!(@insight)

    assert_equal [ @subscription.id ],
      PushDelivery.apns.where(insight: @insight).pluck(:subscription_id)
  end

  test "delivers a privacy-preserving insight notification from the ledger" do
    delivery = record_delivery
    response = stub(ok?: true)
    client = mock
    Apns::Client.expects(:new).with(environment: "sandbox").returns(client)
    client.expects(:deliver).with(
      token: @subscription.token,
      title: "New financial insight",
      body: "Open Sure to review your latest insight.",
      insight_id: @insight.id
    ).returns(response)

    assert_enqueued_jobs 1, only: DeliverInsightNotificationJob do
      PushDelivery.enqueue_insight_deliveries(@insight)
    end
    clear_enqueued_jobs
    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)

    assert_equal "accepted", delivery.reload.status
    assert_equal 1, delivery.provider_attempts
  end

  test "does not push a household total computed from accounts someone can no longer open" do
    @insight.update!(metadata: @insight.metadata.merge("accounts_digest" => "an-account-set-that-changed"))
    Apns::Client.expects(:new).never

    DeliverInsightNotificationJob.perform_now(insight_id: @insight.id, push_subscription_id: @subscription.id)
  end

  test "localizes notifications using the family locale" do
    @insight.family.update!(locale: "de")
    delivery = record_delivery
    response = stub(ok?: true)
    client = mock
    Apns::Client.stubs(:new).returns(client)
    client.expects(:deliver).with(
      token: @subscription.token,
      title: "Neue Finanzanalyse",
      body: "Öffne Sure, um deine neueste Analyse anzusehen.",
      insight_id: @insight.id
    ).returns(response)

    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)
  end

  test "does not record or push an insight whose account is no longer shared with everyone" do
    @insight.update!(metadata: @insight.metadata.merge("account_id" => accounts(:connected).id))
    PushDelivery.record_for_insight!(@insight)
    assert_empty PushDelivery.apns.where(insight: @insight)

    Apns::Client.expects(:new).never
    assert_no_enqueued_jobs do
      PushDelivery.enqueue_insight_deliveries(@insight)
    end
  end

  test "low priority and non-active insights are never recorded or enqueued" do
    Apns::Client.expects(:new).never
    [ { priority: "low" }, { status: "read" }, { status: "expired" }, { status: "acknowledged" } ].each do |attributes|
      @insight.update!(attributes)
      PushDelivery.record_for_insight!(@insight)
      assert_no_enqueued_jobs do
        PushDelivery.enqueue_insight_deliveries(@insight)
      end
      assert_empty PushDelivery.apns.where(insight: @insight)
    end
  end

  test "eligibility changes after recording skip the send at claim time" do
    delivery = record_delivery
    @insight.mark_read!
    Apns::Client.expects(:new).never
    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)
    assert_equal "skipped", delivery.reload.status
  end

  test "a stale registration cannot claim a recorded delivery" do
    delivery = record_delivery
    @subscription.update!(last_registered_at: 91.days.ago)
    Apns::Client.expects(:new).never
    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)
    assert_equal "skipped", delivery.reload.status
  end

  test "a deactivated user cannot claim a recorded delivery" do
    delivery = record_delivery
    @subscription.user.update_column(:active, false)
    Apns::Client.expects(:new).never
    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)
    assert_equal "skipped", delivery.reload.status
  end

  test "preview opt out after recording prevents delivery at claim time" do
    delivery = record_delivery
    @user.update!(preferences: {})
    Apns::Client.expects(:new).never
    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)
    assert_equal "skipped", delivery.reload.status
  end

  test "a ledger row for a subscription that changed users cannot reach the replacement" do
    delivery = record_delivery
    @subscription.update!(device_key_digest: Digest::SHA256.hexdigest("cd" * 32))
    next_user = @insight.family.users.where.not(id: @subscription.user_id).first!
    replacement = PushSubscription.register_for!(user: next_user, token: @subscription.token,
      environment: "sandbox", platform: "ios", device_key: "cd" * 32)
    Apns::Client.expects(:new).never

    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)

    assert PushSubscription.exists?(replacement.id)
    assert_not PushSubscription.exists?(@subscription.id)
    assert_not PushDelivery.exists?(delivery.id)
  end

  test "transient failures hand the attempt back to the ledger and stay pending" do
    delivery = record_delivery
    response = stub(ok?: false, status: "503", body: {})
    Apns::Client.any_instance.stubs(:deliver).returns(response)

    assert_enqueued_jobs 1, only: DeliverInsightNotificationJob do
      DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)
    end
    assert_equal "pending", delivery.reload.status
    assert_equal 1, delivery.reload.provider_attempts
  end

  test "five transient attempts exhaust the ledger budget terminally" do
    delivery = record_delivery
    PushDelivery.enqueue_insight_deliveries(@insight)
    clear_enqueued_jobs
    response = stub(ok?: false, status: "500", body: {})
    Apns::Client.any_instance.stubs(:deliver).returns(response)

    assert_performed_jobs 5, only: DeliverInsightNotificationJob do
      perform_enqueued_jobs only: DeliverInsightNotificationJob do
        DeliverInsightNotificationJob.perform_later(push_delivery_id: delivery.id)
      end
    end
    assert_equal "failed", delivery.reload.status

    Apns::Client.expects(:new).never
    assert_no_enqueued_jobs only: DeliverInsightNotificationJob do
      PushDelivery.retry_enqueue_failures_for(@insight.family)
      PushDelivery.enqueue_insight_deliveries(@insight)
      DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)
    end
  end

  test "a late accepted response cannot be replayed into a second push" do
    delivery = record_delivery
    response = stub(ok?: true)
    Apns::Client.any_instance.expects(:deliver).once.returns(response)

    2.times { DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id) }
    assert_equal "accepted", delivery.reload.status
    assert_equal 1, delivery.reload.provider_attempts
  end

  test "unregistered tokens are invalidated together with their ledger rows" do
    delivery = record_delivery
    sibling = PushDelivery.create!(subscription: @subscription, insight: @insight, insight_version: 2)
    response = stub(ok?: false, status: "410", body: { "reason" => "Unregistered" })
    Apns::Client.any_instance.stubs(:deliver).returns(response)

    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)

    assert_not PushSubscription.exists?(@subscription.id)
    assert_not PushDelivery.exists?(delivery.id)
    assert_not PushDelivery.exists?(sibling.id)
  end

  test "self hosted mode records no apns rows and cannot execute a stale row" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    PushDelivery.record_for_insight!(@insight)
    assert_empty PushDelivery.apns.where(insight: @insight)
    Apns::Client.expects(:new).never
    assert_no_enqueued_jobs do
      PushDelivery.enqueue_insight_deliveries(@insight)
      stale_row = PushDelivery.create!(subscription: @subscription, insight: @insight,
        insight_version: @insight.notification_version)
      DeliverInsightNotificationJob.perform_now(push_delivery_id: stale_row.id)
      assert_equal "pending", stale_row.reload.status
    end
  end

  test "a channel that cannot attempt releases the reservation without burning the budget" do
    delivery = record_delivery
    Apns::Client.stubs(:available?).returns(true, false)
    Apns::Client.expects(:new).never

    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)

    assert_equal "pending", delivery.reload.status
    assert_equal 0, delivery.reload.provider_attempts
    assert_nil delivery.reload.attempted_at
    assert_nil delivery.reload.enqueued_at
  end

  test "configuration failures record as failed rather than a provider rejection" do
    delivery = record_delivery
    Apns::Client.stubs(:new).raises(Apns::Client::ConfigurationError, "bad key")

    DeliverInsightNotificationJob.perform_now(push_delivery_id: delivery.id)

    assert_equal "failed", delivery.reload.status
    assert_equal 1, delivery.reload.provider_attempts
  end

  test "jobs queued before the ledger still deliver exactly once" do
    response = stub(ok?: true)
    client = mock
    Apns::Client.expects(:new).with(environment: "sandbox").returns(client)
    client.expects(:deliver).once.returns(response)

    2.times do
      DeliverInsightNotificationJob.perform_now(
        insight_id: @insight.id, push_subscription_id: @subscription.id
      )
    end

    row = PushDelivery.apns.find_by!(subscription: @subscription, insight: @insight,
      insight_version: @insight.notification_version)
    assert_equal "accepted", row.reload.status
    assert_equal 1, row.provider_attempts
  end

  private
    def record_delivery
      PushDelivery.record_for_insight!(@insight)
      PushDelivery.apns.find_by!(subscription: @subscription, insight: @insight,
        insight_version: @insight.notification_version)
    end
end
