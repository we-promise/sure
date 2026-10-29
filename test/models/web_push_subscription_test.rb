require "test_helper"
require Rails.root.join("test/support/web_push_test_helper")

class WebPushSubscriptionTest < ActiveSupport::TestCase
  include WebPushTestHelper

  setup do
    @user = users(:family_admin)
    @session = @user.sessions.create!
    @attributes = web_push_attributes
  end

  test "updates the current session registration without duplicating it" do
    first = WebPushSubscription.register_for!(user: @user, session: @session, **@attributes)
    assert_no_difference "WebPushSubscription.count" do
      second = WebPushSubscription.register_for!(user: @user, session: @session, **@attributes)
      assert_equal first.id, second.id
    end
    assert_equal @session.id, first.session_id
    assert_equal Digest::SHA256.hexdigest(@attributes[:endpoint]), first.endpoint_digest
  end

  test "endpoint knowledge alone cannot steal another user's registration" do
    original = register_web_push(**@attributes)
    other_user = users(:family_member)
    assert_raises ActiveRecord::RecordInvalid do
      register_web_push(user: other_user, endpoint: @attributes[:endpoint])
    end
    assert_equal @user.id, original.reload.user_id
  end

  test "proof of both subscription keys replaces the old row when the browser changes users" do
    original = register_web_push(**@attributes)
    other_user = users(:family_member)
    replacement = register_web_push(user: other_user, **@attributes)
    assert_not_equal original.id, replacement.id
    assert_not WebPushSubscription.exists?(original.id)
    assert_equal other_user.id, replacement.user_id
  end

  test "a new session replaces the old registration even for the same user" do
    original = WebPushSubscription.register_for!(user: @user, session: @session, **@attributes)
    replacement = register_web_push(**@attributes)
    assert_not_equal original.id, replacement.id
    assert_not WebPushSubscription.exists?(original.id)
  end

  test "rejects sessions belonging to another user" do
    assert_raises ActiveRecord::RecordInvalid do
      WebPushSubscription.register_for!(user: users(:family_member), session: @session, **@attributes)
    end
  end

  test "accepts the supported browser push services" do
    %w[https://web.push.apple.com/Q https://fcm.googleapis.com/fcm/send/Q https://updates.push.services.mozilla.com/wpush/v2/Q https://wns2-db5p.notify.windows.com/w/?token=Q].each do |endpoint|
      assert register_web_push(endpoint: endpoint).persisted?, endpoint
    end
  end

  test "rejects non-public or unrecognized endpoint destinations" do
    %w[http://fcm.googleapis.com/Q https://localhost/Q https://127.0.0.1/Q https://169.254.169.254/Q https://fcm.googleapis.com.evil.test/Q https://evilpush.apple.com/Q https://push.apple.com.evil.test/Q https://fcm.googleapis.com:8443/Q https://user@fcm.googleapis.com/Q https://fcm.googleapis.com/Q#fragment https://example.org/Q].each do |endpoint|
      assert_raises(ActiveRecord::RecordInvalid, endpoint) { register_web_push(endpoint: endpoint) }
    end
    assert_raises(ActiveRecord::RecordInvalid) { register_web_push(endpoint: "https://fcm.googleapis.com/" + "a" * 4096) }
  end

  test "rejects invalid lengths encodings and off-curve public keys" do
    [ { p256dh: "!" * 87 }, { p256dh: Base64.urlsafe_encode64("\x04" + "\x00" * 64, padding: false) },
      { p256dh: Base64.urlsafe_encode64("a" * 33, padding: false) }, { auth: "x" * 22 },
      { auth: Base64.urlsafe_encode64("a" * 15, padding: false) }, { auth: "a" * 1000 } ].each do |invalid|
      assert_raises(ActiveRecord::RecordInvalid) { register_web_push(**@attributes.merge(invalid)) }
    end
  end

  test "revoked and expired sessions cannot receive notifications" do
    subscription = WebPushSubscription.register_for!(user: @user, session: @session, **@attributes)
    assert subscription.eligible?
    @session.update_columns(updated_at: 31.days.ago)
    assert_not subscription.reload.eligible?
    @session.touch
    @session.destroy!
    assert_not WebPushSubscription.exists?(subscription.id)
  end

  test "registration secrets are filtered from request logs" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(@attributes.stringify_keys)
    assert_equal "[FILTERED]", filtered["endpoint"]
    assert_equal "[FILTERED]", filtered["p256dh"]
    assert_equal "[FILTERED]", filtered["auth"]
  end
end
