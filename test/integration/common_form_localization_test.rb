require "test_helper"

class CommonFormLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    ensure_tailwind_build
  end

  LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
    test "#{locale} localizes ordinary create and edit actions" do
      [
        [ "tag", new_tag_path, edit_tag_path(tags(:one)), {} ],
        [ "family_merchant", new_family_merchant_path, edit_family_merchant_path(merchants(:netflix)), {} ],
        [ "account", new_depository_path, edit_depository_path(accounts(:depository)), {} ],
        [ "rule", new_rule_path, edit_rule_path(rules(:one)), { resource_type: "transaction" } ]
      ].each do |model, create_path, update_path, parameters|
        { "create" => create_path, "update" => update_path }.each do |action, path|
          get path, params: parameters.merge(locale: locale)
          assert_response :success
          expected = I18n.t("helpers.submit.#{model}.#{action}", locale: locale, fallback: false, raise: true)
          assert_select "form button[type='submit']", text: expected
          assert_select ".translation_missing", count: 0
        end
      end
      assert_select "h3", text: I18n.t("rules.form.if", locale: locale, fallback: false, raise: true)
    end
  end

  test "Chinese forms do not expose Rails model names" do
    get new_tag_path, params: { locale: "zh-CN" }
    assert_select "form button[type='submit']", text: "新建标签"
    get new_family_merchant_path, params: { locale: "zh-CN" }
    assert_select "form button[type='submit']", text: "新建商户"
    get new_depository_path, params: { locale: "zh-CN" }
    assert_select "form button[type='submit']", text: "新建账户"
    get new_rule_path, params: { locale: "zh-CN", resource_type: "transaction" }
    assert_select "form button[type='submit']", text: "新建规则"
    assert_select "h3", text: "如果"
  end
end

class PasswordResetFormLocalizationTest < ActionDispatch::IntegrationTest
  setup { ensure_tailwind_build }

  test "password reset action uses its translated purpose in every locale" do
    token = users(:family_admin).generate_token_for(:password_reset)
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get edit_password_reset_path(token: token), params: { locale: locale }
      assert_response :success
      assert_select "form button[type='submit']", text: I18n.t("password_resets.new.submit", locale: locale, fallback: false, raise: true)
      assert_select ".translation_missing", count: 0
    end
  end
end
