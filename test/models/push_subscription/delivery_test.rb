require "test_helper"

class PushSubscription::DeliveryTest < ActiveSupport::TestCase
  setup do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Apns::Client.stubs(:configured?).returns(true)
    @subscription = users(:sure_support_staff).push_subscriptions.create!(
      token: "ab" * 32, environment: "sandbox", platform: "ios", last_registered_at: 1.minute.ago
    )
  end

  test "retries throttling and transient server failures" do
    %w[429 500 503].each do |status|
      assert_raises(Apns::Client::TransientError) { deliver(status) }
    end
  end

  test "permanent errors preserve the subscription and redact response details" do
    %w[400 403 413].each do |status|
      assert_equal :rejected, deliver(status, { "reason" => @subscription.token })
    end
    assert PushSubscription.exists?(@subscription.id)
    refute_includes DebugLogEntry.last.message, @subscription.token
    refute_includes DebugLogEntry.last.metadata.to_json, @subscription.token
  end

  test "invalidates an unchanged unregistered token" do
    assert_difference "PushSubscription.count", -1 do
      assert_equal :unregistered, deliver("410", { "timestamp" => Time.current.to_i * 1000 })
    end
  end

  test "a response predating registration cannot invalidate the token" do
    assert_no_difference "PushSubscription.count" do
      deliver("410", { "timestamp" => 2.minutes.ago.to_i * 1000 })
    end
  end

  test "renewal while APNs is responding is preserved" do
    original = @subscription
    PushSubscription.find(original.id).update!(last_registered_at: Time.current)
    assert_no_difference "PushSubscription.count" do
      deliver("410", { "timestamp" => Time.current.to_i * 1000 })
    end
  end

  test "malformed invalidation timestamp cannot remove a token" do
    assert_no_difference "PushSubscription.count" do
      deliver("410", { "timestamp" => "invalid" })
    end
  end

  test "self hosted mode never constructs a transport even when configured" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    Apns::Client.expects(:new).never
    assert_equal :skipped, deliver("200")
  end

  private
    def deliver(status, body = {})
      PushSubscription::Delivery.new(@subscription).call { stub(ok?: status == "200", status: status, body: body) }
    end
end
