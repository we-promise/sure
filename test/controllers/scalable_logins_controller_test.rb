require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableLoginsControllerTest < ActionDispatch::IntegrationTest
  include ScalableTestHelper

  setup do
    @user = scalable_owner
    sign_in @user
    @session_id = @user.sessions.order(:created_at).last.id.to_s
    Current.reset
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
  end

  teardown { Current.reset }

  test "starts device login and renders only the user code and official approval link" do
    provider = mock("Scalable login provider")
    Provider::Scalable.expects(:new).returns(provider)
    provider.expects(:start_login).returns(scalable_pending_state)

    post start_scalable_login_path

    assert_response :see_other
    assert_redirected_to scalable_login_path
    item = ScalableItem.find_by!(family: @user.family, owner: @user)
    state = JSON.parse(item.pending_login_state)
    assert_equal @session_id, state.fetch("session_id")
    assert_equal "synthetic-device-secret", state.fetch("device_code")

    raw_state = ScalableItem.connection.select_value(
      "SELECT pending_login_state FROM scalable_items WHERE id = #{ScalableItem.connection.quote(item.id)}"
    )
    refute_includes raw_state, "synthetic-device-secret"
    refute_includes raw_state, "synthetic-private-key"

    follow_redirect!

    assert_response :success
    assert_select "[data-controller='scalable-login']"
    assert_select "a[href='https://secure.scalable.capital/activate'][target='_blank'][rel='noopener noreferrer']"
    assert_includes response.body, "ABCD-EFGH"
    assert_select "header p", text: I18n.t("scalable_logins.show.profile_security_note")
    refute_includes response.body, "synthetic-device-secret"
    refute_includes response.body, "synthetic-private-key"
    assert_select "form[action=?][method=post]", poll_scalable_login_path, count: 0
    assert_select "form[action=?][method=post]", cancel_scalable_login_path do
      assert_select "input[name=_method][value=delete]"
    end

    get settings_providers_path
    assert_response :success
    assert_includes response.body, "Scalable Capital"
    get connect_form_settings_providers_path(provider_key: "scalable")
    assert_response :success
    assert_select "a[href=?]", scalable_login_path
  end

  test "poll passes the current session and returns updated approval timing" do
    scalable_pending_item
    next_expiry = 4.minutes.from_now.utc.iso8601
    summary = { phase: "phone_approval", expires_at: next_expiry, poll_interval: 17 }
    ScalableItem.any_instance.expects(:poll_login!).with(
      attempt_id: "synthetic-attempt",
      session_id: @session_id
    ).returns(:pending)
    ScalableItem.any_instance.expects(:pending_login_summary).with(session_id: @session_id).returns(summary)

    post poll_scalable_login_path,
      params: { scalable_login: { attempt_id: "synthetic-attempt" } }, as: :json

    assert_response :success
    assert_equal "pending", response.parsed_body.fetch("state")
    assert_equal "phone_approval", response.parsed_body.fetch("phase")
    assert_equal Time.iso8601(next_expiry).to_i, Time.iso8601(response.parsed_body.fetch("expires_at")).to_i
    assert_equal 17, response.parsed_body.fetch("poll_interval")
  end

  test "authentication queues the first sync and redirects the browser to accounts" do
    scalable_pending_item
    ScalableItem.any_instance.expects(:poll_login!).with(
      attempt_id: "synthetic-attempt",
      session_id: @session_id
    ).returns(:authenticated)
    ScalableItem.any_instance.expects(:syncing?).returns(false)
    ScalableItem.any_instance.expects(:sync_later).once

    post poll_scalable_login_path,
      params: { scalable_login: { attempt_id: "synthetic-attempt" } }, as: :json

    assert_response :success
    assert_equal "connected", response.parsed_body.fetch("state")
    assert_equal accounts_path, response.parsed_body.fetch("redirect_url")
    refute_includes response.body, "synthetic-access"
    refute_includes response.body, "synthetic-private-key"
  end

  test "another owner cannot see or poll this connection" do
    scalable_pending_item
    other = users(:empty)
    other.update!(preferences: (other.preferences || {}).merge("preview_features_enabled" => true))
    sign_in other
    Current.reset

    post poll_scalable_login_path,
      params: { scalable_login: { attempt_id: "synthetic-attempt" } }, as: :json

    assert_response :not_found
  end

  test "managed installs and users without preview access cannot start a login" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get scalable_login_path
    assert_response :not_found

    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    get scalable_login_path
    assert_redirected_to root_path
  end

  private

    def scalable_pending_item
      ScalableItem.create!(
        family: @user.family,
        owner: @user,
        status: :pending,
        pending_login_state: JSON.generate(
          scalable_pending_state.merge(
            "attempt_id" => "synthetic-attempt",
            "session_id" => @session_id,
            "owner_id" => @user.id,
            "family_id" => @user.family_id,
            "generation" => 0,
            "deadline" => scalable_pending_state.fetch("expires_at"),
            "next_poll_at" => Time.current.utc.iso8601
          )
        )
      )
    end
end
