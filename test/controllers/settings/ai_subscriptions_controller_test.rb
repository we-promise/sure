require "test_helper"

class Settings::AiSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "shows the AI subscriptions settings page" do
    get settings_ai_subscriptions_path

    assert_response :success
    assert_select "h1", text: I18n.t("settings.ai_subscriptions.show.page_title")
    assert_includes response.body, I18n.t("settings.ai_subscriptions.show.codex.title")
  end

  test "prefers a connected Codex CLI over a stale login attempt" do
    Provider::Codex.stubs(:configured?).returns(true)
    Provider::Codex.stubs(:authentication_status).returns(state: "connected")
    Provider::Codex.stubs(:login_state).returns({ "state" => "awaiting_auth" })

    get settings_ai_subscriptions_path(login_id: SecureRandom.uuid)

    assert_response :success
    assert_includes response.body, I18n.t("settings.ai_subscriptions.show.codex.sign_out")
    assert_not_includes response.body, I18n.t("settings.ai_subscriptions.show.codex.sign_in")
  end

  test "requires an administrator" do
    sign_in users(:family_member)

    get settings_ai_subscriptions_path

    assert_response :redirect
  end

  test "starts ChatGPT sign-in through the worker" do
    Provider::Codex.stubs(:configured?).returns(true)
    Provider::Codex.expects(:prepare_login).with { |login_id| login_id.match?(/\A[0-9a-f-]{36}\z/) }.once
    CodexLoginJob.expects(:perform_later).with { |login_id| login_id.match?(/\A[0-9a-f-]{36}\z/) }.once

    post settings_ai_subscriptions_codex_login_path

    assert_response :redirect
    assert_includes response.location, settings_ai_subscriptions_path
    assert_match(/login_id=/, response.location)
  end

  test "signs out of ChatGPT through Codex" do
    Provider::Codex.expects(:perform_logout).returns(true)

    post settings_ai_subscriptions_codex_logout_path

    assert_redirected_to settings_ai_subscriptions_path
    assert_equal I18n.t("settings.ai_subscriptions.show.codex.signed_out"), flash[:notice]
  end
end
