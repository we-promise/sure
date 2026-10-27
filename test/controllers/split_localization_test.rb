require "test_helper"

class SplitLocalizationTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @entry = create_transaction(amount: 100, name: "Synthetic <split> & original", account: accounts(:depository))
  end

  test "new and edit split editors render localized templates for dynamic rows" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get new_transaction_split_path(@entry), params: { locale: locale }
      assert_split_labels(locale, @entry.name)
    end

    @entry.split!([
      { name: "Synthetic <child> & original", amount: 60, category_id: nil },
      { name: "Second synthetic child", amount: 40, category_id: nil }
    ])
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get edit_transaction_split_path(@entry), params: { locale: locale }
      assert_split_labels(locale, "Synthetic <child> & original")
    end
  end

  test "dynamic row labels are escaped in the server-rendered template" do
    original = I18n.t("splits.new.name_label", locale: :en)
    unsafe_label = %(<img src=x onerror="synthetic()">)
    I18n.backend.store_translations(:en, splits: { new: { name_label: unsafe_label } })

    get new_transaction_split_path(@entry), params: { locale: :en }

    assert_response :success
    template = Nokogiri::HTML.fragment(response.body).at_css("template[data-split-transaction-target='rowTemplate']")
    assert_includes template.text, unsafe_label
    assert_empty template.css("img[onerror], script")
  ensure
    I18n.backend.store_translations(:en, splits: { new: { name_label: original } }) if original
  end

  private
    def assert_split_labels(locale, original_name)
      assert_response :success
      html = Nokogiri::HTML.fragment(response.body)
      form = html.at_css("form[data-controller='split-transaction']")
      template = form.at_css("template[data-split-transaction-target='rowTemplate']")
      assert template, "#{locale}: dynamic row template must be present"
      %w[name_label amount_label category_label merchant_label no_merchant tags_label uncategorized].each do |key|
        expected = I18n.t("splits.new.#{key}", locale: locale, fallback: false, raise: true)
        assert_includes template.text, expected, "#{locale}: #{key}"
      end
      name_input = template.at_css("input[data-split-transaction-target='nameInput']")
      assert_equal I18n.t("splits.new.name_placeholder", locale: locale, fallback: false, raise: true), name_input["placeholder"]
      assert_includes name_input["name"], "ROW_IDX_PLACEHOLDER"
      remove = template.at_css("button[data-action='click->split-transaction#removeRow']")
      assert_equal I18n.t("splits.new.remove_row", locale: locale, fallback: false, raise: true), remove["aria-label"]
      assert_equal @entry.currency, form["data-split-transaction-currency-value"]
      assert_equal(-100, form["data-split-transaction-total-value"].to_f)
      assert html.css("input[data-split-transaction-target='nameInput']").any? { |input| input["value"] == original_name }
      assert_empty html.css("child, split, .translation_missing")
    end
end
