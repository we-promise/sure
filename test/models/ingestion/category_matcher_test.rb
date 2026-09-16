require "test_helper"
require "ostruct"

class Ingestion::CategoryMatcherTest < ActiveSupport::TestCase
  test "legacy ASCII candidates match the established Plaid taxonomy across punctuation and alias forms" do
    names = [ "Income", "Dividend Income", "Salary", "Groceries", "Loan Payments", "Food & Drink", "Fees", "Entertainment",
      "Café", "Candy", "Groceriés", "Furniture", "INCOME_WAGES", "Shopping", "Stock Income", "Insurance", "Car", "Giving" ]
    categories = names.each_with_index.map { |name, index| OpenStruct.new(id: index, name: name) }
    legacy = PlaidAccount::Transactions::CategoryMatcher.new(categories)
    matcher = Ingestion::CategoryMatcher.new(categories, locale: :en)
    PlaidAccount::Transactions::CategoryTaxonomy::CATEGORIES_MAP.each_value do |parent|
      parent.fetch(:detailed_categories).each do |key, child|
        hints = { normalization: "legacy_ascii", exact_names: [ key.to_s ], aliases: child.fetch(:aliases), fallback_aliases: parent.fetch(:aliases) }
        assert_equal legacy.match(key.to_s)&.id, matcher.match(hints)&.id, "Plaid taxonomy mismatch for #{key}"
      end
    end
  end

  test "detailed aliases win over an earlier parent category and exact tier retains literal candidate behavior" do
    income = OpenStruct.new(id: 1, name: "Income")
    wage_key = OpenStruct.new(id: 2, name: "INCOME_WAGES")
    salary = OpenStruct.new(id: 3, name: "Salary")
    hints = { normalization: "legacy_ascii", exact_names: [ "income_wages" ], aliases: [ "salary" ], fallback_aliases: [ "income" ] }
    assert_equal salary, Ingestion::CategoryMatcher.new([ income, wage_key, salary ], locale: :en).match(hints)
    assert_equal income, Ingestion::CategoryMatcher.new([ income, wage_key ], locale: :en).match(hints)
    assert_nil Ingestion::CategoryMatcher.new([ wage_key ], locale: :en).match(hints)
    assert_equal wage_key, Ingestion::CategoryMatcher.new([ wage_key ], locale: :en).match(hints.merge(exact_names: [ "income wages" ]))
  end

  test "legacy aliases keep raw spelling and unbounded and removal without changing the general matcher" do
    candy = OpenStruct.new(id: 1, name: "Candy")
    cafe = OpenStruct.new(id: 2, name: "Café")
    matcher = Ingestion::CategoryMatcher.new([ candy, cafe ], locale: :en)
    assert_equal candy, matcher.match(normalization: "legacy_ascii", aliases: [ "cy" ])
    assert_nil matcher.match(aliases: [ "cy" ])
    assert_nil matcher.match(normalization: "legacy_ascii", aliases: [ "Café" ])
    assert_equal cafe, matcher.match(aliases: [ "Café" ])
  end

  test "ordinary translated candidates keep translation-first and existing alias behavior" do
    translated = OpenStruct.new(id: 1, name: "Groceries")
    alias_category = OpenStruct.new(id: 2, name: "Market")
    I18n.expects(:t).with("test.grocery", locale: "en", default: nil).returns("Groceries")
    matcher = Ingestion::CategoryMatcher.new([ alias_category, translated ], locale: :en)
    assert_equal translated, matcher.match(translation_key: "test.grocery", aliases: [ "Market" ])
  end
end
