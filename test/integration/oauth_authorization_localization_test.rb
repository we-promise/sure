require "test_helper"

class OauthAuthorizationLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    @user.family.update!(auto_sync_on_login: false)
    sign_in @user
    # An unsaved OAuth client with an inert identifier: this test issues no credentials or grants.
    @client = Doorkeeper::Application.new(name: "Synthetic <client> & original", uid: "synthetic-ui-client", redirect_uri: "sureapp://oauth/callback", scopes: "read")
    Doorkeeper::Application.stubs(:by_uid).with(@client.uid).returns(@client)
    @authorization_params = { client_id: @client.uid, redirect_uri: @client.redirect_uri, response_type: "code", scope: "read", state: "synthetic-state", display: "mobile" }
  end

  %w[en zh-CN pt-PT].each do |locale|
    test "authorization page uses #{locale} request locale without changing user preferences or grants" do
      @user.update!(locale: "en")
      Current.reset
      assert_no_difference [ "Doorkeeper::Application.count", "Doorkeeper::AccessGrant.count", "Doorkeeper::AccessToken.count", "Session.count" ] do
        get "/oauth/authorize", params: @authorization_params.merge(locale: locale)
      end
      assert_response :success
      assert_select "html[lang=?]", locale
      assert_select "h2", text: I18n.t("authentication_ui.authorization.title", locale: locale, product_name: Rails.configuration.x.product_name)
      assert_equal "en", @user.reload.locale
      assert_select "form[data-turbo='false']", count: 2
      assert_select "input[name=scope][value=read]", count: 2
      assert_select "input[name=state][value=synthetic-state]", count: 2
      assert_select "client", count: 0
      assert_includes response.body, "Synthetic &lt;client&gt; &amp; original"
    end
  end

  test "authorization restores authenticated user locale before rendering and keeps it request scoped" do
    @user.update!(locale: "pt-PT")
    Current.reset
    original_locale = I18n.locale
    get "/oauth/authorize", params: @authorization_params
    assert_response :success
    assert_select "html[lang='pt-PT']"
    assert_equal original_locale, I18n.locale
    assert_equal "pt-PT", @user.reload.locale
  end

  test "family locale is used without persisting a browser preference for a user with no locale" do
    @user.update!(locale: nil)
    @user.family.update!(locale: "zh-CN")
    Current.reset
    get "/oauth/authorize", params: @authorization_params, headers: { "Accept-Language" => "pt-PT" }
    assert_response :success
    assert_select "html[lang='zh-CN']"
    assert_nil @user.reload.locale
  end

  test "invalid locale parameters fall back to user locale without saving browser preferences" do
    @user.update!(locale: "zh-CN")
    Current.reset
    get "/oauth/authorize", params: @authorization_params.merge(locale: [ "pt-PT" ]), headers: { "Accept-Language" => "pt-PT" }
    assert_response :success
    assert_select "html[lang='zh-CN']"
    assert_equal "zh-CN", @user.reload.locale
  end
end
