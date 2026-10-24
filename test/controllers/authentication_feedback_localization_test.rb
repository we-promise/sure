require "test_helper"

class RegistrationFeedbackLocalizationTest < ActionController::TestCase
  tests RegistrationsController

  CASE_MESSAGES = {
    "en" => [ "must include both uppercase and lowercase letters", "must include at least one number", "must include at least one special character" ],
    "zh-CN" => [ "必须同时包含大写和小写字母", "必须包含至少一个数字", "必须包含至少一个特殊字符" ],
    "pt-PT" => [ "deve incluir letras maiúsculas e minúsculas", "deve incluir pelo menos um número", "deve incluir pelo menos um carácter especial" ]
  }.freeze

  setup { ensure_tailwind_build }

  CASE_MESSAGES.each do |locale, messages|
    { "Aa1!" => nil, "password1!" => 0, "Password!" => 1, "Password1" => 2 }.each do |password, message_index|
      test "#{locale} registration explains the failed password rule without changing it #{message_index || 'length'}" do
        assert_no_difference [ "User.count", "Family.count", "Session.count" ] do
          post :create, params: { locale: locale, user: { email: "synthetic-localization@example.invalid", password: password, password_confirmation: password } }
        end
        assert_response :unprocessable_entity
        user = @controller.instance_variable_get(:@user)
        assert_equal password, user.password
        assert_equal [ :password ], user.errors.attribute_names
        expected_message = message_index.nil? ? I18n.t("errors.messages.too_short", locale: locale, count: 8) : messages.fetch(message_index)
        expected_full = I18n.with_locale(locale) { ActiveModel::Error.full_message(:password, expected_message, user) }
        assert_equal [ expected_full ], I18n.with_locale(locale) { user.errors.full_messages }
        assert_select "p", text: expected_full
        label = User.human_attribute_name(:password, locale: locale)
        assert_equal 1, expected_full.scan(label).size
      end
    end
  end
end

class OidcLinkFeedbackLocalizationTest < ActionController::TestCase
  tests OidcAccountsController

  %w[en zh-CN pt-PT].each do |locale|
    test "#{locale} failed link uses localized login feedback and preserves pending authentication" do
      pending = { "provider" => "openid_connect", "uid" => "synthetic-localization-identity", "email" => "synthetic-localization@example.invalid" }
      session[:pending_oidc_auth] = pending
      User.expects(:authenticate_by).with(email: pending.fetch("email"), password: "synthetic-invalid-input").returns(nil)
      assert_no_difference [ "User.count", "OidcIdentity.count", "Session.count", "SsoAuditLog.count" ] do
        post :create_link, params: { locale: locale, email: pending.fetch("email"), password: "synthetic-invalid-input" }
      end
      assert_response :unprocessable_entity
      assert_equal I18n.t("sessions.create.invalid_credentials", locale: locale), flash[:alert]
      assert_equal pending, session[:pending_oidc_auth]
    end
  end
end
