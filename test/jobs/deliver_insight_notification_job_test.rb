require "test_helper"

class DeliverInsightNotificationJobTest < ActiveJob::TestCase
  setup do
    @insight = insights(:cash_flow_warning)
    @subscription = @insight.family.users.first.push_subscriptions.create!(
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
end
