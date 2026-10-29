require "test_helper"
require Rails.root.join("test/support/web_push_test_helper")

class WebPushClientTest < ActiveSupport::TestCase
  include WebPushTestHelper

  setup do
    @subscription = register_web_push
    @vapid = { public_key: "test-public-key", private_key: "test-private-key", subject: "mailto:operator@example.test" }
    WebPush::Client.stubs(:vapid).returns(@vapid)
  end

  test "uses the web push library for standards based encryption and VAPID delivery" do
    payload = { title: "Sure", body: "A new financial alert is available." }
    WebPush.expects(:payload_send).with do |options|
      options[:endpoint] == @subscription.endpoint && options[:p256dh] == @subscription.p256dh &&
        options[:auth] == @subscription.auth && JSON.parse(options[:message]) == payload.stringify_keys &&
        options[:vapid] == @vapid && options[:open_timeout].positive? && options[:read_timeout].positive?
    end.returns(true)
    assert_equal :accepted, WebPush::Client.new.deliver(subscription: @subscription, payload: payload)
  end

  test "revalidates persisted endpoints before contacting a provider" do
    @subscription.update_column(:endpoint, "https://169.254.169.254/latest/meta-data")
    WebPush.expects(:payload_send).never
    assert_equal :rejected, WebPush::Client.new.deliver(subscription: @subscription.reload, payload: {})
  end

  test "network failures have a sanitized transient error" do
    WebPush.stubs(:payload_send).raises(Net::ReadTimeout, "secret endpoint #{@subscription.endpoint}")
    error = assert_raises(WebPush::Client::TransientError) do
      WebPush::Client.new.deliver(subscription: @subscription, payload: {})
    end
    assert_not_includes error.message, @subscription.endpoint
    assert_not_includes error.message, @subscription.auth
  end
  test "invalid subscriptions are gone while retryable provider failures are sanitized" do
    [ WebPush::InvalidSubscription, WebPush::ExpiredSubscription ].each do |error_class|
      WebPush.stubs(:payload_send).raises(error_class.new(stub(body: "provider details"), "fcm.googleapis.com"))
      assert_equal :gone, WebPush::Client.new.deliver(subscription: @subscription, payload: {})
    end
    [ WebPush::TooManyRequests, WebPush::PushServiceError ].each do |error_class|
      WebPush.stubs(:payload_send).raises(error_class.new(stub(body: "sensitive provider details"), "fcm.googleapis.com"))
      error = assert_raises(WebPush::Client::TransientError) do
        WebPush::Client.new.deliver(subscription: @subscription, payload: {})
      end
      assert_not_includes error.message, "sensitive provider details"
    end
  end

  test "other provider rejections do not retry or follow redirects" do
    WebPush.stubs(:payload_send).raises(WebPush::ResponseError.new(stub(body: "redirect or rejection"), "fcm.googleapis.com"))
    assert_equal :rejected, WebPush::Client.new.deliver(subscription: @subscription, payload: {})
  end

  test "configuration validates a real VAPID pair and contact URI" do
    WebPush::Client.unstub(:vapid)
    key = WebPush.generate_key
    values = { WEB_PUSH_VAPID_PUBLIC_KEY: key.public_key, WEB_PUSH_VAPID_PRIVATE_KEY: key.private_key,
      WEB_PUSH_VAPID_SUBJECT: "mailto:operator@example.test" }
    ClimateControl.modify(values) { assert WebPush::Client.configured? }
    [ { WEB_PUSH_VAPID_PRIVATE_KEY: nil }, { WEB_PUSH_VAPID_PUBLIC_KEY: "invalid" },
      { WEB_PUSH_VAPID_SUBJECT: "http://example.test" }, { WEB_PUSH_VAPID_SUBJECT: "mailto:" },
      { WEB_PUSH_VAPID_PRIVATE_KEY: WebPush.generate_key.private_key } ].each do |invalid|
      ClimateControl.modify(values.merge(invalid)) { assert_not WebPush::Client.configured? }
    end
  end

end
