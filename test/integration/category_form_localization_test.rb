require "test_helper"

class CategoryFormLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    ensure_tailwind_build
    @category = categories(:food_and_drink)
    @category.update!(name: "Synthetic 用户分类", emoji: "👩🏽‍💻")
  end

  LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
    test "#{locale} renders category create and update actions without fallback" do
      get new_category_path, params: { locale: locale }
      assert_response :success
      assert_submit "create", locale

      get edit_category_path(@category), params: { locale: locale }
      assert_response :success
      assert_submit "update", locale
      assert_select "input[name='category[name]'][value='Synthetic 用户分类']"
      assert_select "input[name='category[emoji]'][value='👩🏽‍💻']"
    end

    test "#{locale} renders actionable emoji errors for invalid creation and editing" do
      assert_no_difference "Category.count" do
        post categories_path, params: {
          locale: locale,
          category: { name: "Synthetic invalid 用户分类", color: "#123456", lucide_icon: "coffee", emoji: "😀😀" }
        }
      end
      assert_response :unprocessable_entity
      assert_emoji_error locale
      assert_submit "create", locale
      assert_select "input[name='category[name]'][value='Synthetic invalid 用户分类']"
      assert_select "input[name='category[emoji]'][value='😀😀']"

      patch category_path(@category), params: { locale: locale, category: { emoji: "letters" } }
      assert_response :unprocessable_entity
      assert_emoji_error locale
      assert_submit "update", locale
      assert_select "input[name='category[name]'][value='Synthetic 用户分类']"
      assert_select "input[name='category[emoji]'][value='letters']"
      assert_equal "👩🏽‍💻", @category.reload.emoji
      assert_equal "Synthetic 用户分类", @category.name
    end
  end

  test "ordinary tag forms localize the shared submitting state in every locale" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get new_tag_path, params: { locale: locale }
      assert_response :success
      pending = I18n.t("shared.submitting", locale: locale, fallback: false, raise: true)
      assert_select "form button[type='submit'][data-turbo-submits-with=?]", pending
    end
  end

  test "Chinese category actions and emoji error do not expose English model names" do
    get new_category_path, params: { locale: "zh-CN" }
    assert_select "form button[type='submit']", text: "新建分类"

    get edit_category_path(@category), params: { locale: "zh-CN" }
    assert_select "form button[type='submit']", text: "更新分类"

    post categories_path, params: {
      locale: "zh-CN", category: { name: "Synthetic invalid emoji", color: "#123456", emoji: "😀😀" }
    }
    assert_response :unprocessable_entity
    assert_select "form p.text-destructive", text: "表情符号必须是一个完整的表情符号"
    refute_includes response.body, "Emoji is invalid"
  end

  private
    def assert_submit(action, locale)
      expected = I18n.t("helpers.submit.category.#{action}", locale: locale, fallback: false, raise: true)
      assert_select "form button[type='submit']", text: expected
      pending = I18n.t("shared.submitting", locale: locale, fallback: false, raise: true)
      assert_select "form button[type='submit'][data-turbo-submits-with=?]", pending
      refute_includes expected, "Category" unless locale == "en"
    end

    def assert_emoji_error(locale)
      attribute = I18n.t("activerecord.attributes.category.emoji", locale: locale, fallback: false, raise: true)
      message = I18n.t("activerecord.errors.models.category.attributes.emoji.invalid", locale: locale, fallback: false, raise: true)
      assert_select "form p.text-destructive", text: /#{Regexp.escape(attribute)}/
      assert_select "form p.text-destructive", text: /#{Regexp.escape(message)}/
      refute_includes response.body, "Emoji is invalid"
      assert_select ".translation_missing", count: 0
    end
end
