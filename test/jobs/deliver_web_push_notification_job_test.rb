require "test_helper"
require Rails.root.join("test/support/web_push_test_helper")

class DeliverWebPushNotificationJobTest < ActiveJob::TestCase
  include WebPushTestHelper

  setup do
    @user = users(:family_admin)
    enable_web_push_preview(@user)
    @insight = insights(:cash_flow_warning)
    @subscription = register_web_push(user: @user)
    WebPush::Client.stubs(:configured?).returns(true)
    @client = mock
    WebPush::Client.stubs(:new).returns(@client)
  end

  test "enqueues only once for a subscription and material insight version" do
    assert_enqueued_jobs 1, only: DeliverWebPushNotificationJob do
      2.times { DeliverWebPushNotificationJob.enqueue_for(@insight) }
    end
    assert_equal 1, WebPushDelivery.where(web_push_subscription: @subscription, insight: @insight).count
  end

  test "an enqueue failure can be recovered by a later generation pass" do
    DeliverWebPushNotificationJob.stubs(:perform_later).returns(false)
    delivery = enqueue_delivery
    assert_equal "enqueue_failed", delivery.reload.status
    delivery.update_columns(created_at: 2.days.ago)
    DeliverWebPushNotificationJob.unstub(:perform_later)
    assert_enqueued_jobs 1, only: DeliverWebPushNotificationJob do
      DeliverWebPushNotificationJob.retry_enqueue_failures_for(@insight.family)
    end
    assert_equal "pending", delivery.reload.status
    @client.expects(:deliver).returns(:accepted)
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
    assert_equal "accepted", delivery.reload.status
  end

  test "delivers generic lock screen content and a same origin insight link" do
    delivery = enqueue_delivery
    @client.expects(:deliver).with do |subscription:, payload:|
      subscription.id == @subscription.id &&
        payload[:title] == "Sure" &&
        payload[:body] == I18n.t("web_push.notification.body") &&
        payload[:data][:path] == "/insights#insight_#{@insight.id}" &&
        !payload.to_json.include?(@insight.title) && !payload.to_json.include?(@insight.body)
    end.returns(:accepted)
    2.times { DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id) }
    assert_equal "accepted", delivery.reload.status
  end

  test "localizes the generic payload with the family locale" do
    @insight.family.update!(locale: "de")
    delivery = enqueue_delivery
    @client.expects(:deliver).with do |subscription:, payload:|
      payload[:body] == I18n.t("web_push.notification.body", locale: :de)
    end.returns(:accepted)
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
  end

  test "a material version can be delivered again without replaying the old version" do
    first = enqueue_delivery
    @insight.increment!(:notification_version)
    assert_enqueued_jobs 1, only: DeliverWebPushNotificationJob do
      DeliverWebPushNotificationJob.enqueue_for(@insight.reload)
    end
    assert_equal 2, WebPushDelivery.where(insight: @insight).count
    @client.expects(:deliver).never
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: first.id)
  end

  test "budget warnings require independent opt in even at high priority" do
    @insight.update!(insight_type: "budget_at_risk")
    %w[high medium].each do |priority|
      @insight.update!(priority: priority)
      assert_no_enqueued_jobs { DeliverWebPushNotificationJob.enqueue_for(@insight) }
    end
    @user.update!(preferences: @user.preferences.merge("web_push_budget_warnings_enabled" => true))
    assert_enqueued_jobs 1, only: DeliverWebPushNotificationJob do
      DeliverWebPushNotificationJob.enqueue_for(@insight)
    end
  end

  test "never sends budget on track or ordinary medium priority insights" do
    @user.update!(preferences: @user.preferences.merge("web_push_budget_warnings_enabled" => true))
    [ { insight_type: "budget_on_track", priority: "high" },
      { insight_type: "spending_anomaly", priority: "medium" },
      { insight_type: "budget_at_risk", priority: "low" } ].each do |attributes|
      @insight.update!(attributes)
      assert_no_enqueued_jobs { DeliverWebPushNotificationJob.enqueue_for(@insight) }
    end
  end

  test "budget opt out after enqueue prevents delivery" do
    @insight.update!(insight_type: "budget_at_risk")
    @user.update!(preferences: @user.preferences.merge("web_push_budget_warnings_enabled" => true))
    delivery = enqueue_delivery
    @user.update!(preferences: @user.preferences.merge("web_push_budget_warnings_enabled" => false))
    @client.expects(:deliver).never
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
  end

  [ { status: "read" }, { status: "dismissed" }, { status: "expired" },
    { metadata: { account_id: "private_account" } }, { family_id: "other_family" } ].each do |attributes|
    test "send rechecks insight eligibility after #{attributes.keys.first} changes to #{attributes.values.first}" do
      delivery = enqueue_delivery
      changed = attributes.deep_dup
      changed[:metadata] = { account_id: accounts(:connected).id } if changed[:metadata]
      changed[:family_id] = families(:empty).id if changed[:family_id]
      @insight.update!(changed)
      @client.expects(:deliver).never
      DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
    end
  end

  test "preview opt out after enqueue prevents delivery" do
    delivery = enqueue_delivery
    @user.update!(preferences: {})
    @client.expects(:deliver).never
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
  end

  test "deactivating the user after enqueue prevents delivery" do
    delivery = enqueue_delivery
    @user.update_column(:active, false)
    @client.expects(:deliver).never
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
  end

  test "expired revoked or replaced sessions cannot receive a queued notification" do
    delivery = enqueue_delivery
    @client.expects(:deliver).never
    @subscription.session.update_columns(updated_at: 31.days.ago)
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
    @subscription.session.touch
    attributes = @subscription.attributes.symbolize_keys.slice(:endpoint, :p256dh, :auth)
    register_web_push(user: users(:family_member), **attributes)
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
  end

  test "self hosted mode delivers browser push independently of APNs restrictions" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    delivery = enqueue_delivery
    @client.expects(:deliver).returns(:accepted)
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
    assert_equal "accepted", delivery.reload.status
  end

  test "gone subscriptions are removed after provider rejection" do
    delivery = enqueue_delivery
    @client.expects(:deliver).returns(:gone)
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
    assert_not WebPushSubscription.exists?(@subscription.id)
  end

  test "transient failures schedule a bounded retry without marking accepted" do
    delivery = enqueue_delivery
    @client.expects(:deliver).raises(WebPush::Client::TransientError)
    assert_enqueued_jobs 1, only: DeliverWebPushNotificationJob do
      DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
    end
    assert_not_equal "accepted", delivery.reload.status
  end

  test "configuration removed after enqueue prevents delivery" do
    delivery = enqueue_delivery
    WebPush::Client.stubs(:configured?).returns(false)
    @client.expects(:deliver).never
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
  end

  private
    def enqueue_delivery
      DeliverWebPushNotificationJob.enqueue_for(@insight)
      WebPushDelivery.find_by!(web_push_subscription: @subscription, insight: @insight,
        insight_version: @insight.notification_version)
    end
end
