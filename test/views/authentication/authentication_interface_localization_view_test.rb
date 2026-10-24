require "test_helper"

class AuthenticationInterfaceLocalizationViewTest < ActionView::TestCase
  MESSAGE_KEYS = %w[copy_failed issuer_valid issuer_mismatch_trailing issuer_mismatch browser_validation_unavailable testing request_failed].freeze

  setup do
    ensure_tailwind_build
    Current.session = sessions(:one)
  end

  test "SSO form supplies escaped translations for every locale without credentials or connection requests" do
    provider = SsoProvider.new(strategy: "openid_connect", name: "synthetic_localization", label: "Synthetic <label> & original")
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        html = Nokogiri::HTML.fragment(render(partial: "admin/sso_providers/form", locals: { sso_provider: provider }))
        form = html.at_css("form[data-controller='admin-sso-form']")
        assert form["data-admin-sso-form-messages-value"], "#{locale}: SSO feedback translations must be supplied"
        messages = JSON.parse(form["data-admin-sso-form-messages-value"])
        MESSAGE_KEYS.each do |key|
          expected = I18n.t("authentication_ui.sso.#{key}", fallback: false, raise: true, issuer: "%{issuer}", message: "%{message}")
          assert_equal expected, messages.fetch(key), "#{locale}: #{key}"
        end
        assert_equal I18n.t("settings.api_keys.key_reveal.copied", fallback: false, raise: true), messages.fetch("copied")
        assert_equal I18n.t("admin.sso_providers.form.test_connection", fallback: false, raise: true), messages.fetch("test_connection")
        assert_equal provider.label, html.at_css("input[name='sso_provider[label]']")["value"]
        assert_empty html.css("label[original]")
      end
    end
  end

  %w[en zh-CN pt-PT].each do |locale|
    test "#{locale} authorization copy preserves OAuth fields and escapes names" do
      @pre_auth = OpenStruct.new(
        client: OpenStruct.new(name: "Synthetic <client> & original", uid: "synthetic-client-id"),
        scopes: [ "read" ], redirect_uri: "sureapp://oauth/callback", state: "synthetic-state",
        response_type: "code", response_mode: "query", scope: "read",
        code_challenge: "synthetic-challenge", code_challenge_method: "S256"
      )
      params[:redirect_uri] = @pre_auth.redirect_uri
      params[:display] = "mobile"
      I18n.with_locale(locale) do
        html = Nokogiri::HTML.fragment(render(template: "doorkeeper/authorizations/new"))
        assert_includes html.text, I18n.t("authentication_ui.authorization.explanation", product_name: Rails.configuration.x.product_name, fallback: false, raise: true)
        %w[authorizing denying].each do |key|
          expected = I18n.t("authentication_ui.authorization.#{key}", fallback: false, raise: true)
          assert html.css("[data-disable-with]").any? { |node| node["data-disable-with"] == expected }, "#{locale}: #{key}"
        end
        assert_includes html.text, @pre_auth.client.name
        assert_empty html.css("client")
        assert_equal 2, html.css("form[data-turbo='false']").size
        { client_id: @pre_auth.client.uid, state: @pre_auth.state, redirect_uri: @pre_auth.redirect_uri,
          response_type: "code", response_mode: "query", scope: "read", code_challenge: "synthetic-challenge",
          code_challenge_method: "S256", display: "mobile" }.each do |name, value|
          assert_equal [ value, value ], html.css("input[name='#{name}']").map { |node| node["value"] }
        end
        layout = Nokogiri::HTML(render(template: "doorkeeper/authorizations/new", layout: "layouts/doorkeeper/application"))
        assert_equal I18n.t("authentication_ui.authorization.title", product_name: Rails.configuration.x.product_name, fallback: false, raise: true), layout.at_css("h2").text.strip
        assert_equal locale, layout.at_css("html")["lang"]
      end
    end
  end

  test "new authentication labels and password attribute names exist explicitly in all supported locales" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      %w[missing_case missing_number missing_special].each do |key|
        assert I18n.t("authentication_ui.password.#{key}", locale: locale, fallback: false, raise: true).present?
      end
      assert I18n.t("activerecord.attributes.user.password", locale: locale, fallback: false, raise: true).present?
      assert I18n.t("authentication_ui.authorization.title", product_name: "Sure", locale: locale, fallback: false, raise: true).present?
    end
  end
end
