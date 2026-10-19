require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableItem::LoginTest < ActiveSupport::TestCase
  include ScalableTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    @owner = scalable_owner
    @session = @owner.sessions.create!
    @item = ScalableItem.new(family: @owner.family, owner: @owner)
    @provider = mock("provider")
    @provider.stubs(:start_login).returns(scalable_pending_state)
    @login = ScalableItem::Login.new(@item, provider: @provider)
  end

  test "device challenge is encrypted and can only be polled in its owning Sure session" do
    assert_equal :pending, @login.start(session_id: @session.id)
    travel 6.seconds
    summary = @login.summary(session_id: @session.id)
    assert_equal "ABCD-EFGH", summary.fetch(:user_code)
    refute summary.key?(:device_code)
    stored = ScalableItem.connection.select_value("SELECT pending_login_state FROM scalable_items WHERE id = #{ScalableItem.connection.quote(@item.id)}")
    refute_includes stored, "synthetic-device-secret"
    other_session = @owner.sessions.create!
    assert_nil @login.summary(session_id: other_session.id)
    @provider.expects(:poll_login).never
    error = assert_raises(Provider::Scalable::Error) do
      @login.poll(attempt_id: summary.fetch(:attempt_id), session_id: other_session.id)
    end
    assert_equal "challenge_not_available", error.code
    assert @item.reload.pending_login_state
  end

  test "automatically finishes after verified approval and prevents replay" do
    @login.start(session_id: @session.id)
    travel 6.seconds
    attempt_id = @login.summary(session_id: @session.id).fetch(:attempt_id)
    @provider.expects(:poll_login).once.returns(Provider::Scalable::LoginResult.new(state: :authenticated, pending_state: nil, credentials: scalable_credentials))
    assert_equal :authenticated, @login.poll(attempt_id: attempt_id, session_id: @session.id)
    assert @item.reload.session_configured?
    assert_nil @item.pending_login_state
    assert_equal 1, @item.connection_generation
    error = assert_raises(Provider::Scalable::Error) { @login.poll(attempt_id: attempt_id, session_id: @session.id) }
    assert_equal "challenge_not_available", error.code
  end

  test "expired challenge deletion is committed before reporting the error" do
    @login.start(session_id: @session.id)
    travel 6.seconds
    attempt_id = @login.summary(session_id: @session.id).fetch(:attempt_id)
    travel 11.minutes do
      @provider.expects(:poll_login).never
      error = assert_raises(Provider::Scalable::Error) { @login.poll(attempt_id: attempt_id, session_id: @session.id) }
      assert_equal "challenge_expired", error.code
    end
    assert_nil @item.reload.pending_login_state
  end

  test "a failed reconnect to a different person keeps the original session and saved data" do
    @item = scalable_connected_item(owner: @owner)
    @login = ScalableItem::Login.new(@item, provider: @provider)
    @login.start(session_id: @session.id)
    travel 6.seconds
    attempt_id = @login.summary(session_id: @session.id).fetch(:attempt_id)
    @provider.expects(:poll_login).returns(Provider::Scalable::LoginResult.new(state: :authenticated, pending_state: nil, credentials: scalable_credentials(person: "other-person")))
    error = assert_raises(Provider::Scalable::Error) { @login.poll(attempt_id: attempt_id, session_id: @session.id) }
    assert_equal "account_identity_changed", error.code
    assert @item.reload.session_configured?
    assert_equal "synthetic-person", @item.person_identity
    assert_equal 1, @item.connection_generation
    assert_nil @item.pending_login_state
  end

  test "server polling deadline prevents duplicate token requests" do
    @login.start(session_id: @session.id)
    travel 6.seconds
    state = scalable_pending_state
    @provider.expects(:poll_login).once.returns(Provider::Scalable::LoginResult.new(state: :pending, pending_state: state, credentials: nil))
    attempt_id = @login.summary(session_id: @session.id).fetch(:attempt_id)
    assert_equal :pending, @login.poll(attempt_id: attempt_id, session_id: @session.id)
    assert_equal :pending, @login.poll(attempt_id: attempt_id, session_id: @session.id)
  end

  test "no provider requests are made without explicit encryption or owner authorization" do
    @provider.expects(:start_login).never
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    error = assert_raises(Provider::Scalable::Error) { @login.start(session_id: @session.id) }
    assert_equal "encryption_unavailable", error.code
    refute @item.persisted?
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    @owner.update!(role: :member)
    error = assert_raises(Provider::Scalable::Error) { @login.start(session_id: @session.id) }
    assert_equal "login_authorization_changed", error.code
  end
end
