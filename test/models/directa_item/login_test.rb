require "test_helper"

class DirectaItem::LoginTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @owner.update!(preferences: (@owner.preferences || {}).merge("preview_features_enabled" => true))
    @session = @owner.sessions.create!
    @session_id = @session.id.to_s
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    @item = DirectaItem.new(family: @family, owner: @owner)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
  end

  test "stores the OTP challenge encrypted and binds it to the Sure session" do
    challenge = login_challenge(
      account_number: "00X12",
      challenge_token: "directa-challenge-secret",
      connection_generation: 1
    )
    client = mock("Directa login client")
    client.expects(:begin_login).with(
      account_number: "00X12",
      password: "broker-password-secret",
      connection_generation: 1
    ).returns(challenge)
    password = "broker-password-secret"

    assert_equal :otp_required, DirectaItem::Login.new(@item, provider: client).start(
      broker_account: "X12",
      password: password,
      session_id: @session_id
    )

    assert_equal "broker-password-secret", password
    assert @item.reload.pending?
    assert_not @item.session_configured?
    summary = @item.pending_login_summary(session_id: @session_id)
    assert_equal 3, summary.fetch(:attempts_remaining)
    other_session = @owner.sessions.create!
    assert_nil @item.pending_login_summary(session_id: other_session.id.to_s)

    stored_state = DirectaItem.connection.select_value(
      "SELECT pending_login_state FROM directa_items WHERE id = #{ActiveRecord::Base.connection.quote(@item.id)}"
    )
    refute_includes stored_state, "directa-challenge-secret"
    refute_includes stored_state, "broker-password-secret"
    refute_includes stored_state, "00X12"
    refute @item.has_attribute?(:password)
  end

  test "clears its copied password buffer without mutating the caller's value" do
    challenge = login_challenge(account_number: "00123", challenge_token: "otp-challenge", connection_generation: 1)
    password = "broker-password-secret".freeze
    provider_password = nil
    client = Object.new
    client.define_singleton_method(:begin_login) do |password:, **_arguments|
      provider_password = password
      challenge
    end

    assert_equal :otp_required, DirectaItem::Login.new(@item, provider: client).start(
      broker_account: "123",
      password: password,
      session_id: @session_id
    )

    assert_equal "broker-password-secret", password
    assert_empty provider_password
  end

  test "three rejected OTP submissions expire the challenge and cannot be replayed" do
    challenge = login_challenge(account_number: "00123", challenge_token: "otp-challenge", connection_generation: 1)
    client = mock("Directa login client")
    client.expects(:begin_login).returns(challenge)
    client.expects(:complete_login).times(3).returns(challenge)

    login = DirectaItem::Login.new(@item, provider: client)
    assert_equal :otp_required, login.start(broker_account: "123", password: "secret", session_id: @session_id)
    attempt_id = @item.pending_login_summary(session_id: @session_id).fetch(:attempt_id)

    assert_equal :otp_required, login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)
    assert_equal :otp_required, login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)
    assert_equal :attempts_exhausted, login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)

    assert_nil @item.reload.pending_login_state
    assert @item.requires_update?
    error = assert_raises(DirectaItem::Login::Error) do
      login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)
    end
    assert_equal "challenge_not_available", error.code
  end

  test "an OTP challenge cannot be completed from another Sure session" do
    challenge = login_challenge(account_number: "00123", challenge_token: "otp-challenge", connection_generation: 1)
    client = mock("Directa login client")
    client.expects(:begin_login).returns(challenge)
    client.expects(:complete_login).never
    login = DirectaItem::Login.new(@item, provider: client)
    login.start(broker_account: "123", password: "secret", session_id: @session_id)
    other_session = @owner.sessions.create!
    attempt_id = @item.pending_login_summary(session_id: @session_id).fetch(:attempt_id)

    error = assert_raises(DirectaItem::Login::Error) do
      login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: other_session.id.to_s)
    end

    assert_equal "challenge_not_available", error.code
    assert @item.reload.pending_login_state.present?
  end

  test "a successful OTP consumes the pending challenge and a replay makes no provider call" do
    challenge = login_challenge(account_number: "00123", challenge_token: "otp-challenge", connection_generation: 1)
    session = verified_session(account_number: "00123", account_identity: "directa-account-123", connection_generation: 1)
    client = mock("Directa login client")
    client.expects(:begin_login).returns(challenge)
    client.expects(:complete_login).once.returns(session)
    login = DirectaItem::Login.new(@item, provider: client)
    login.start(broker_account: "123", password: "secret", session_id: @session_id)
    attempt_id = @item.pending_login_summary(session_id: @session_id).fetch(:attempt_id)

    assert_equal :authenticated, login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)
    assert @item.reload.connected?
    assert @item.session_configured?
    assert_nil @item.pending_login_state
    assert_equal "directa-account-123", @item.account_identity
    assert_equal 1, @item.connection_generation

    error = assert_raises(DirectaItem::Login::Error) do
      login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)
    end
    assert_equal "challenge_not_available", error.code
  end

  test "a failed reconnect with a changed Directa identity preserves the old session and generation" do
    @item.update!(
      broker_account: "00123",
      account_identity: "original-directa-account",
      multi_token: "old-multi-token",
      mono_token: "old-mono-token",
      status: :connected,
      connection_generation: 7,
      portfolio_snapshot_at: 1.day.ago
    )
    session = verified_session(account_number: "00123", account_identity: "different-account", connection_generation: 8)
    client = mock("Directa login client")
    client.expects(:begin_login).returns(session)
    login = DirectaItem::Login.new(@item, provider: client)

    error = assert_raises(DirectaItem::Login::Error) do
      login.start(broker_account: "123", password: "secret", session_id: @session_id)
    end

    assert_equal "account_identity_changed", error.code
    assert @item.reload.connected?
    assert_equal "original-directa-account", @item.account_identity
    assert_equal "old-multi-token", @item.multi_token
    assert_equal "old-mono-token", @item.mono_token
    assert_equal 7, @item.connection_generation
    assert_equal 1.day.ago.to_i, @item.portfolio_snapshot_at.to_i
    assert_nil @item.pending_login_state
  end

  test "encryption must be explicitly configured before credentials are sent" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    client = mock("Directa login client")
    client.expects(:begin_login).never

    error = assert_raises(DirectaItem::Login::Error) do
      DirectaItem::Login.new(@item, provider: client).start(
        broker_account: "123",
        password: "secret",
        session_id: @session_id
      )
    end

    assert_equal "encryption_unavailable", error.code
    assert_not @item.persisted?
  end

  test "the local expiry is five minutes and is not extended by repeated page reads" do
    now = Time.zone.parse("2026-10-18 12:00:00")
    challenge = login_challenge(account_number: "00123", challenge_token: "otp-challenge", connection_generation: 1)
    client = mock("Directa login client")
    client.expects(:begin_login).returns(challenge)
    login = DirectaItem::Login.new(@item, provider: client, clock: -> { now })
    login.start(broker_account: "123", password: "secret", session_id: @session_id)

    assert_equal 3, login.summary(session_id: @session_id).fetch(:attempts_remaining)
    now += 5.minutes
    assert_nil login.summary(session_id: @session_id)
    assert_nil @item.reload.pending_login_state
  end

  test "an ambiguous OTP provider error clears the committed reservation and cannot be retried" do
    challenge = login_challenge(account_number: "00123", challenge_token: "otp-challenge", connection_generation: 1)
    client = mock("Directa login client")
    client.expects(:begin_login).returns(challenge)
    client.expects(:complete_login).once.raises(StandardError, "ambiguous response")
    login = DirectaItem::Login.new(@item, provider: client)
    login.start(broker_account: "123", password: "secret", session_id: @session_id)
    attempt_id = @item.pending_login_summary(session_id: @session_id).fetch(:attempt_id)

    error = assert_raises(DirectaItem::Login::Error) do
      login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)
    end

    assert_equal "provider_unavailable", error.code
    assert_nil @item.reload.pending_login_state
    replay_error = assert_raises(DirectaItem::Login::Error) do
      login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)
    end
    assert_equal "challenge_not_available", replay_error.code
  end

  test "an expired OTP completion commits challenge deletion before reporting expiry" do
    now = Time.zone.parse("2026-10-18 12:00:00")
    challenge = login_challenge(account_number: "00123", challenge_token: "otp-challenge", connection_generation: 1)
    client = mock("Directa login client")
    client.expects(:begin_login).returns(challenge)
    client.expects(:complete_login).never
    login = DirectaItem::Login.new(@item, provider: client, clock: -> { now })
    login.start(broker_account: "123", password: "secret", session_id: @session_id)
    attempt_id = login.summary(session_id: @session_id).fetch(:attempt_id)
    now += 5.minutes

    error = assert_raises(DirectaItem::Login::Error) do
      login.complete(otp_code: "123456", attempt_id: attempt_id, session_id: @session_id)
    end

    assert_equal "challenge_expired", error.code
    assert_nil @item.reload.pending_login_state
  end

  test "a Sure session revoked during Directa login cannot commit the returned token" do
    session = verified_session(account_number: "00123", account_identity: "directa-account-123", connection_generation: 1)
    session_id = @session_id
    client = Object.new
    client.define_singleton_method(:begin_login) do |**_arguments|
      Session.find(session_id).destroy!
      session
    end
    login = DirectaItem::Login.new(@item, provider: client)

    error = assert_raises(DirectaItem::Login::Error) do
      login.start(broker_account: "123", password: "secret", session_id: @session_id)
    end

    assert_equal "login_authorization_changed", error.code
    assert_nil @item.reload.pending_login_state
    assert_not @item.connected?
    assert_nil @item.multi_token
    assert_nil @item.mono_token
  end

  private

    def login_challenge(account_number:, challenge_token:, connection_generation:)
      Provider::Directa::LoginChallenge.new(
        account_number: account_number,
        challenge_token: challenge_token,
        connection_generation: connection_generation
      )
    end

    def verified_session(account_number:, account_identity:, connection_generation:)
      Provider::Directa::VerifiedSession.new(
        account_number: account_number,
        account_identity: account_identity,
        multi_token: "multi-token-#{connection_generation}",
        mono_token: "mono-token-#{connection_generation}",
        host: Provider::Directa::HOST,
        connection_generation: connection_generation
      )
    end
end
