require "test_helper"

class SplitLocalizationTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @entry = create_transaction(amount: 100, name: "Synthetic <split> & original", account: accounts(:depository))
  end

  test "new and edit split editors pass explicit locale labels to dynamic rows" do
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

  private
    def assert_split_labels(locale, original_name)
      assert_response :success
      html = Nokogiri::HTML.fragment(response.body)
      form = html.at_css("form[data-controller='split-transaction']")
      assert form["data-split-transaction-labels-value"], "#{locale}: dynamic-row translations must reach Stimulus"
      labels = JSON.parse(form["data-split-transaction-labels-value"])
      { name: "name_label", amount: "amount_label", name_placeholder: "name_placeholder", uncategorized: "uncategorized", remove: "remove_row" }.each do |name, key|
        expected = I18n.t("splits.new.#{key}", locale: locale, fallback: false, raise: true)
        assert_equal expected, labels.fetch(name.to_s), "#{locale}: #{name}"
      end
      assert_equal @entry.currency, form["data-split-transaction-currency-value"]
      assert_equal(-100, form["data-split-transaction-total-value"].to_f)
      assert html.css("input[data-split-transaction-target='nameInput']").any? { |input| input["value"] == original_name }
      assert_empty html.css("child, split, .translation_missing")
    end
end
