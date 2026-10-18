require "test_helper"
require Rails.root.join("test/support/ca_auto_bank_test_helper")

class CaAutoBankLoginsControllerTest < ActionDispatch::IntegrationTest
  include CaAutoBankTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    CaAutoBankItem.any_instance.stubs(:sync_later)
    CaAutoBankItem.any_instance.stubs(:syncing?).returns(false)
    sign_in @user
    Current.reset
    @bank_root = "#{Provider::CaAutoBank::ORIGIN}#{Provider::CaAutoBank::AUTH_ROOT}"
  end

  teardown { Current.reset }

  test "login form is discoverable from bank sync and does not cache or echo credentials" do
    get ca_auto_bank_login_path
    assert_response :success
    assert_select "input[type=email][autocomplete=username][required]"
    assert_select "input[type=password][autocomplete=current-password][required]"
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    get settings_providers_path
    assert_response :success
    assert_includes response.body, "CA Auto Bank"
    get connect_form_settings_providers_path(provider_key: "ca_auto_bank")
    assert_response :success
    assert_select "a[href=?]", ca_auto_bank_login_path
  end

  test "phone approval stores only an encrypted session-bound challenge and authenticates automatically" do
    start_challenge
    assert_response :see_other
    item = CaAutoBankItem.find_by!(owner: @user)
    raw = ActiveRecord::Base.connection.select_value("SELECT pending_login_state FROM ca_auto_bank_items WHERE id = #{ActiveRecord::Base.connection.quote(item.id)}")
    refute_includes raw, "private-verification"
    refute_includes item.pending_login_state, "synthetic-password"
    follow_redirect!
    assert_select "[data-controller=ca-auto-bank-login]"
    refute_includes response.body, "private-verification"
    attempt = JSON.parse(item.pending_login_state).fetch("attempt_id")
    token = ca_token
    stub_request(:post, "#{@bank_root}/login/tfa").to_return(status: 200, body: { authenticationToken: token }.to_json)
    stub_request(:get, "#{@bank_root}/user").to_return(status: 200, body: { partnerId: "synthetic-partner" }.to_json)
    CaAutoBankItem.any_instance.expects(:sync_later).once
    post poll_ca_auto_bank_login_path, params: { ca_auto_bank_login: { attempt_id: attempt } }, as: :json
    assert_response :success
    assert_equal "connected", response.parsed_body.fetch("state")
    assert item.reload.connected?
    assert_nil item.pending_login_state
    assert_equal token, item.authentication_token
    refute_includes response.body, token
    assert_equal "synthetic-partner", item.account_identity
  end

  test "pending polls are throttled server-side and cancellation prevents further bank calls" do
    start_challenge
    item = CaAutoBankItem.find_by!(owner: @user)
    attempt = JSON.parse(item.pending_login_state).fetch("attempt_id")
    poll_request = stub_request(:post, "#{@bank_root}/login/tfa")
      .to_return(status: 511, body: { errorCode: 5110003, appAuthorizationRequired: true }.to_json)
    2.times { post poll_ca_auto_bank_login_path, params: { ca_auto_bank_login: { attempt_id: attempt } }, as: :json }
    assert_requested poll_request, times: 1
    assert_equal "pending", response.parsed_body.fetch("state")
    delete cancel_ca_auto_bank_login_path, params: { ca_auto_bank_login: { attempt_id: attempt } }
    assert_nil item.reload.pending_login_state
    post poll_ca_auto_bank_login_path, params: { ca_auto_bank_login: { attempt_id: attempt } }, as: :json
    assert_response :unprocessable_entity
    assert_requested poll_request, times: 1
  end

  test "a second Sure session cannot complete the first session's bank approval" do
    start_challenge
    item = CaAutoBankItem.find_by!(owner: @user)
    attempt = JSON.parse(item.pending_login_state).fetch("attempt_id")
    sign_in @user
    post poll_ca_auto_bank_login_path, params: { ca_auto_bank_login: { attempt_id: attempt } }, as: :json
    assert_response :unprocessable_entity
    assert_not_requested(:post, "#{@bank_root}/login/tfa")
    assert item.reload.pending_login_state.present?
  end

  test "another household cannot see or complete a saved challenge" do
    start_challenge
    item = CaAutoBankItem.find_by!(owner: @user)
    other = users(:empty)
    other.update!(preferences: (other.preferences || {}).merge("preview_features_enabled" => true))
    sign_in other
    post poll_ca_auto_bank_login_path, params: { ca_auto_bank_login: { attempt_id: JSON.parse(item.pending_login_state).fetch("attempt_id") } }, as: :json
    assert_response :not_found
    assert_not_requested(:post, "#{@bank_root}/login/tfa")
  end

  test "expired approvals are cleared and do not contact the bank" do
    start_challenge
    item = CaAutoBankItem.find_by!(owner: @user)
    attempt = JSON.parse(item.pending_login_state).fetch("attempt_id")
    travel 6.minutes do
      post poll_ca_auto_bank_login_path, params: { ca_auto_bank_login: { attempt_id: attempt } }, as: :json
      assert_response :unprocessable_entity
      assert_nil item.reload.pending_login_state
      assert_not_requested(:post, "#{@bank_root}/login/tfa")
    end
  end

  test "wrong credentials and missing encryption never leak or retain the password" do
    stub_request(:post, "#{@bank_root}/login").to_return(status: 401, body: '{"message":"private backend detail"}')
    post start_ca_auto_bank_login_path, params: { ca_auto_bank_login: { email: "owner@example.com", password: "synthetic-password" } }
    assert_response :unprocessable_entity
    refute_includes response.body, "synthetic-password"
    refute_includes response.body, "private backend detail"
    assert_select "input[type=password][value='synthetic-password']", count: 0

    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    assert_no_difference "CaAutoBankItem.count" do
      post start_ca_auto_bank_login_path, params: { ca_auto_bank_login: { email: "owner@example.com", password: "another-password" } }
    end
    assert_response :unprocessable_entity
    assert_requested(:post, "#{@bank_root}/login", times: 1)
  end

  test "reconnection with a different bank identity leaves the previous authenticated connection intact" do
    item = ca_connected_item
    original_token = item.authentication_token
    start_challenge
    attempt = JSON.parse(item.reload.pending_login_state).fetch("attempt_id")
    stub_request(:post, "#{@bank_root}/login/tfa").to_return(status: 200, body: { authenticationToken: ca_token(expires_at: 90.minutes.from_now) }.to_json)
    stub_request(:get, "#{@bank_root}/user").to_return(status: 200, body: { partnerId: "different-partner" }.to_json)
    post poll_ca_auto_bank_login_path, params: { ca_auto_bank_login: { attempt_id: attempt } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original_token, item.reload.authentication_token
    assert_equal "synthetic-partner", item.account_identity
    assert_nil item.pending_login_state
  end

  test "managed installs and users without preview access cannot start a bank login" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get ca_auto_bank_login_path
    assert_response :not_found
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    get ca_auto_bank_login_path
    assert_redirected_to root_path
    assert_not_requested(:post, "#{@bank_root}/login")
  end

  private

    def start_challenge
      stub_request(:post, "#{@bank_root}/login").to_return(status: 511,
        body: { errorCode: 5110000, verificationToken: "private-verification", appAuthorizationRequired: true }.to_json)
      post start_ca_auto_bank_login_path, params: { ca_auto_bank_login: { email: "owner@example.com", password: "synthetic-password" } }
    end
end
