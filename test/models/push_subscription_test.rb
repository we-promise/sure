# frozen_string_literal: true

require "test_helper"

class PushSubscriptionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
  end

  test "valid push subscription" do
    subscription = PushSubscription.new(
      user: @user,
      endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
      p256dh_key: "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
      auth_key: "tBHItJI5svbpez7KI4CCXg"
    )
    assert subscription.valid?
  end

  test "requires endpoint" do
    subscription = PushSubscription.new(
      user: @user,
      p256dh_key: "key",
      auth_key: "auth"
    )
    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "can't be blank"
  end

  test "requires unique endpoint" do
    PushSubscription.create!(
      user: @user,
      endpoint: "https://example.com/push/123",
      p256dh_key: "key1",
      auth_key: "auth1"
    )

    duplicate = PushSubscription.new(
      user: @user,
      endpoint: "https://example.com/push/123",
      p256dh_key: "key2",
      auth_key: "auth2"
    )
    assert_not duplicate.valid?
  end
end
