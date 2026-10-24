require "test_helper"

class IcostLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
  end

  test "every selectable locale supplies all iCost text and exact interpolation variables" do
    english = leaves(YAML.load_file(Rails.root.join("config/locales/views/icost_imports/en.yml")).fetch("en").fetch("icost_imports"))
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      path = Rails.root.join("config/locales/views/icost_imports/#{locale}.yml")
      assert path.exist?, "Missing explicit iCost locale #{locale}"
      translated = leaves(YAML.load_file(path).fetch(locale).fetch("icost_imports"))
      assert_equal english.keys.sort, translated.keys.sort, locale
      english.each do |key, value|
        assert translated.fetch(key).is_a?(String) && translated.fetch(key).present?, "#{locale}.#{key}"
        assert_equal value.scan(/%\{\w+\}/).sort, translated.fetch(key).scan(/%\{\w+\}/).sort, "#{locale}.#{key} interpolation"
        assert_equal translated.fetch(key), I18n.t("icost_imports.#{key}", locale: locale, fallback: false, **value.scan(/%\{(\w+)\}/).flatten.to_h { |name| [ name.to_sym, "%{#{name}}" ] }), "#{locale}.#{key} must not use fallback"
      end
      refute_equal english, translated, "#{locale} is an untranslated English copy" unless locale == "en"
      [ 0, 1, 2, 5, 21 ].each do |count|
        assert_includes I18n.t("icost_imports.publish", locale: locale, count: count, fallback: false, raise: true), count.to_s
      end
    end
  end

  test "emoji labels placeholders help and accessibility labels exist without fallback" do
    keys = %w[emoji_label emoji_placeholder emoji_help emoji_clear emoji_pick]
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      keys.each do |key|
        text = I18n.t("categories.form.#{key}", locale: locale, emoji: "👩🏽‍💻", fallback: false, raise: true)
        assert text.present?, "#{locale}.#{key}"
        assert_includes text, "👩🏽‍💻" if key == "emoji_pick"
      end
    end
  end

  test "all selectable locales render iCost pages and category editing without missing translations" do
    batch = IcostImport.prepare!(family: @user.family, user: @user,
      bytes: CSV.generate { |csv|
        csv << %w[日期 类型 金额 一级分类 二级分类 账户1 账户2 备注 货币 标签 账本 位置]
        csv << [ "2026/01/02 03:04:05", "支出", "-1234.56", "Synthetic category", "", "", "", "保留用户备注", "USD", "", "Synthetic book", "Synthetic local place" ]
      }, filename: "synthetic-i18n.csv")
    record = batch.records.first
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      @user.update!(locale: locale)
      [ icost_imports_path, new_icost_import_path, icost_import_path(batch), icost_import_record_path(batch, record), edit_category_path(categories(:food_and_drink)) ].each do |path|
        get path
        assert_response :success
        assert_select ".translation_missing", count: 0
        refute_match(/translation missing|Translation missing|%\{(?:count|row|emoji|index)\}/, response.body)
      end
      get icost_import_record_path(batch, record)
      assert_select "[data-breadcrumbs]", text: /#{Regexp.escape(I18n.t("icost_imports.title", locale: locale))}/
      assert_select "[data-icost-details]", text: /保留用户备注/
      assert_select "[data-icost-details]", text: /2026\/01\/02 03:04:05/
      assert_select "[data-icost-location]", text: /#{Regexp.escape(I18n.t("icost_imports.unknown_coordinate_system", locale: locale))}/
      post icost_imports_path, params: { icost_import: {} }
      assert_redirected_to new_icost_import_path
      assert_equal I18n.t("icost_imports.messages.invalid_upload", locale: locale), flash[:alert]
    end
  end

  test "Chinese settings navigation and bill confirmation preserve meaningful labels" do
    assert_equal "后台任务", I18n.t("settings.settings_nav.background_jobs_label", locale: :"zh-CN", fallback: false, raise: true)
    assert_equal "系统健康", I18n.t("settings.settings_nav.system_health_label", locale: :"zh-CN", fallback: false, raise: true)
    confirmation = I18n.t("recurring_transactions.confirm_delete", locale: :"zh-CN", name: "Synthetic bill", fallback: false, raise: true)
    assert_includes confirmation, "Synthetic bill"
    assert_includes confirmation, "已有交易保持不变"
  end

  private
    def leaves(tree, prefix = nil)
      tree.each_with_object({}) do |(key, value), result|
        path = [ prefix, key ].compact.join(".")
        value.is_a?(Hash) ? result.merge!(leaves(value, path)) : result[path] = value
      end
    end
end
