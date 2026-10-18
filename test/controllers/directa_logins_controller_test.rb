require "test_helper"

class DirectaLoginsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Current.reset
    @session_id = @user.sessions.order(:created_at).last.id.to_s
  end

  teardown do
    Current.reset
  end

  test "login page uses native labeled credential fields and does not cache the page" do
    with_directa_access do
      get directa_login_path
    end

    assert_response :success
    assert_select "form[method=post]"
    assert_select "input#broker_account[autocomplete=username][required]"
    assert_select "input#current-password[type=password][autocomplete='current-password'][required]"
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_includes response.body, I18n.t("directa_logins.show.read_only")
  end

  test "a connected session keeps the reconnect form visible alongside its status" do
    DirectaItem.create!(
      family: @user.family,
      owner: @user,
      broker_account: "00123",
      account_identity: "verified-account-123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      status: :connected,
      connection_generation: 1,
      portfolio_snapshot_at: 1.day.ago
    )

    with_directa_access do
      get directa_login_path
    end

    assert_response :success
    assert_select "p[role=status]", text: I18n.t("directa_logins.show.status_connected")
    assert_select "input#current-password[type=password][autocomplete='current-password']"
    assert_select "input#broker_account[value='00123']"
    assert_includes response.body, I18n.t("directa_logins.show.reconnect_title")
  end

  test "start stores an encrypted challenge and returns no challenge token or password" do
    challenge = Provider::Directa::LoginChallenge.new(
      account_number: "00123",
      challenge_token: "directa-challenge-secret",
      connection_generation: 1
    )
    client = mock("Directa login client")
    client.expects(:begin_login).with(
      account_number: "00123",
      password: "broker-password-secret",
      connection_generation: 1
    ).returns(challenge)
    Provider::Directa.expects(:new).returns(client)

    with_directa_access do
      post start_directa_login_path, params: {
        directa_login: { broker_account: "123", password: "broker-password-secret" }
      }
    end

    assert_response :see_other
    assert_redirected_to directa_login_path
    assert_equal I18n.t("directa_logins.show.otp_requested"), flash[:notice]

    follow_redirect!
    assert_response :success
    item = DirectaItem.find_by!(family: @user.family, owner: @user)
    assert item.pending?
    assert_select "input#directa-otp-code[autocomplete='one-time-code'][inputmode=numeric][required]"
    refute_includes response.body, "directa-challenge-secret"
    refute_includes response.body, "broker-password-secret"
    raw_state = ActiveRecord::Base.connection.select_value(
      "SELECT pending_login_state FROM directa_items WHERE id = #{ActiveRecord::Base.connection.quote(item.id)}"
    )
    refute_includes raw_state, "directa-challenge-secret"
    refute_includes raw_state, "00123"
  end

  test "OTP completion returns only a safe connected state and queues the first read" do
    challenge = Provider::Directa::LoginChallenge.new(
      account_number: "00123",
      challenge_token: "directa-challenge-secret",
      connection_generation: 1
    )
    verified_session = Provider::Directa::VerifiedSession.new(
      account_number: "00123",
      account_identity: "verified-account-123",
      multi_token: "multi-token-secret",
      mono_token: "mono-token-secret",
      host: Provider::Directa::HOST,
      connection_generation: 1
    )
    client = mock("Directa login client")
    client.expects(:begin_login).returns(challenge)
    client.expects(:complete_login).with(
      account_number: "00123",
      challenge_token: "directa-challenge-secret",
      otp_code: "123456",
      connection_generation: 1
    ).returns(verified_session)
    Provider::Directa.expects(:new).twice.returns(client)
    DirectaItem.any_instance.expects(:syncing?).returns(false)
    DirectaItem.any_instance.expects(:sync_later).once

    with_directa_access do
      post start_directa_login_path, params: {
        directa_login: { broker_account: "123", password: "broker-password-secret" }
      }
    end
    item = DirectaItem.find_by!(family: @user.family, owner: @user)
    attempt_id = item.pending_login_summary(session_id: @session_id).fetch(:attempt_id)

    with_directa_access do
      post complete_directa_login_path, params: {
        directa_login: { otp_code: "123456", attempt_id: attempt_id }
      }
    end

    assert_response :see_other
    assert_redirected_to directa_login_path
    assert_equal I18n.t("directa_logins.show.authenticated_waiting_for_sync"), flash[:notice]

    follow_redirect!
    assert_response :success
    assert item.reload.connected?
    assert_equal "verified-account-123", item.account_identity
    assert_equal 1, item.connection_generation
    assert_nil item.pending_login_state
    assert_equal "awaiting_valuation", item.last_sync_error_code
    refute_includes response.body, "multi-token-secret"
    refute_includes response.body, "mono-token-secret"
    refute_includes response.body, "directa-challenge-secret"
  end

  test "an unaccepted one-time code renders a safe retry response" do
    challenge = Provider::Directa::LoginChallenge.new(
      account_number: "00123",
      challenge_token: "directa-challenge-secret",
      connection_generation: 1
    )
    client = mock("Directa login client")
    client.expects(:begin_login).returns(challenge)
    client.expects(:complete_login).returns(challenge)
    Provider::Directa.expects(:new).twice.returns(client)

    with_directa_access do
      post start_directa_login_path, params: {
        directa_login: { broker_account: "123", password: "broker-password-secret" }
      }
    end
    follow_redirect!
    item = DirectaItem.find_by!(family: @user.family, owner: @user)
    attempt_id = item.pending_login_summary(session_id: @session_id).fetch(:attempt_id)

    with_directa_access do
      post complete_directa_login_path, params: {
        directa_login: { otp_code: "123456", attempt_id: attempt_id }
      }
    end

    assert_response :unprocessable_entity
    assert_equal I18n.t("directa_logins.show.invalid_otp", attempts: 2), flash.now[:alert]
    assert_select "input#directa-otp-code[autocomplete='one-time-code']"
    refute_includes response.body, "directa-challenge-secret"
  end

  test "failed credential response never re-renders the password value" do
    client = mock("Directa login client")
    client.expects(:begin_login).raises(StandardError, "upstream failure")
    Provider::Directa.expects(:new).returns(client)

    with_directa_access do
      post start_directa_login_path, params: {
        directa_login: { broker_account: "123", password: "broker-password-secret" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "input#current-password[value='broker-password-secret']", count: 0
    refute_includes response.body, "broker-password-secret"
  end

  test "managed installs and users without preview access cannot open the login flow" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get directa_login_path
    assert_response :not_found

    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    get directa_login_path
    assert_redirected_to root_path
  end

  test "another family administrator cannot complete an owner-scoped challenge" do
    item = DirectaItem.create!(family: @user.family, owner: @user, status: :pending)
    item.update!(
      pending_login_state: JSON.generate(
        account_number: "00123",
        attempt_id: "opaque-attempt-id",
        attempts: 0,
        connection_generation: 1,
        expires_at: 5.minutes.from_now.utc.iso8601,
        family_id: @user.family_id.to_s,
        owner_id: @user.id.to_s,
        session_id: @session_id,
        stage: "otp_required",
        challenge_token: "challenge-secret"
      )
    )
    other_admin = users(:empty)
    other_admin.update!(preferences: (other_admin.preferences || {}).merge("preview_features_enabled" => true))
    sign_in other_admin

    with_directa_access do
      post complete_directa_login_path, params: {
        directa_login: { otp_code: "123456", attempt_id: "opaque-attempt-id" }
      }
    end

    assert_response :unprocessable_entity
    refute_includes response.body, "challenge-secret"
    assert_equal "challenge-secret", JSON.parse(item.reload.pending_login_state).fetch("challenge_token")
  end

  private

    def with_directa_access
      with_self_hosting { yield }
    end
end
