require "test_helper"

class DeliverInsightNotificationJobTest < ActiveJob::TestCase
  setup do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Apns::Client.stubs(:configured?).returns(true)
    @insight = insights(:cash_flow_warning)
    user = @insight.family.users.first
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    @subscription = user.push_subscriptions.create!(
      token: "ab" * 32,
      environment: "sandbox",
      platform: "ios",
      last_registered_at: Time.current
    )
  end

  test "delivers a privacy-preserving insight notification" do
    response = stub(ok?: true)
    client = mock
    Apns::Client.expects(:new).with(environment: "sandbox").returns(client)
    client.expects(:deliver).with(
      token: @subscription.token,
      title: "New financial insight",
      body: "Open Sure to review your latest AI insight.",
      insight_id: @insight.id
    ).returns(response)

    DeliverInsightNotificationJob.perform_now(
      insight_id: @insight.id,
      push_subscription_id: @subscription.id
    )
  end

  test "localizes notifications using the family locale" do
    @insight.family.update!(locale: "de")
    response = stub(ok?: true)
    client = mock
    Apns::Client.stubs(:new).returns(client)
    client.expects(:deliver).with(
      token: @subscription.token,
      title: "Neue Finanzanalyse",
      body: "Öffne Sure, um deine neueste KI-Analyse anzusehen.",
      insight_id: @insight.id
    ).returns(response)

    DeliverInsightNotificationJob.perform_now(
      insight_id: @insight.id,
      push_subscription_id: @subscription.id
    )
  end

  test "removes tokens rejected as unregistered" do
    response = stub(ok?: false, status: "410", body: { "reason" => "Unregistered" })
    Apns::Client.any_instance.stubs(:deliver).returns(response)

    assert_difference "PushSubscription.count", -1 do
      DeliverInsightNotificationJob.perform_now(
        insight_id: @insight.id,
        push_subscription_id: @subscription.id
      )
    end
  end

  test "does not send an insight to a device from another family" do
    other_subscription = users(:empty).push_subscriptions.create!(
      token: "cd" * 32,
      environment: "sandbox",
      platform: "ios",
      last_registered_at: Time.current
    )
    Apns::Client.expects(:new).never

    DeliverInsightNotificationJob.perform_now(
      insight_id: @insight.id,
      push_subscription_id: other_subscription.id
    )
  end

  test "self hosted mode prevents enqueueing and execution of old jobs" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    Apns::Client.expects(:new).never
    assert_no_enqueued_jobs do
      DeliverInsightNotificationJob.enqueue_for(@insight)
      DeliverInsightNotificationJob.perform_now(insight_id: @insight.id, push_subscription_id: @subscription.id)
    end
  end

  test "preview opt out after enqueueing prevents delivery" do
    @subscription.user.update!(preferences: { "preview_features_enabled" => false })
    Apns::Client.expects(:new).never
    DeliverInsightNotificationJob.perform_now(insight_id: @insight.id, push_subscription_id: @subscription.id)
  end

  test "stale registrations and inactive users cannot receive insight pushes" do
    @subscription.update!(last_registered_at: 91.days.ago)
    Apns::Client.expects(:new).never
    DeliverInsightNotificationJob.perform_now(insight_id: @insight.id, push_subscription_id: @subscription.id)
    @subscription.update!(last_registered_at: Time.current)
    @subscription.user.update_column(:active, false)
    DeliverInsightNotificationJob.perform_now(insight_id: @insight.id, push_subscription_id: @subscription.id)
  end

  test "low priority and already read insights cannot enqueue or deliver" do
    Apns::Client.expects(:new).never
    [ { priority: "low" }, { priority: "high", status: "read" }, { status: "expired" }, { status: "acknowledged" } ].each do |attributes|
      @insight.update!(attributes)
      assert_no_enqueued_jobs do
        DeliverInsightNotificationJob.enqueue_for(@insight)
        DeliverInsightNotificationJob.perform_now(insight_id: @insight.id, push_subscription_id: @subscription.id)
      end
    end
  end
end
