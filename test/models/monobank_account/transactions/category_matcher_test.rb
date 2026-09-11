require "test_helper"

class MonobankAccount::Transactions::CategoryMatcherTest < ActiveSupport::TestCase
  Category = Struct.new(:id, :name)

  test "matches an MCC onto the equivalent English default category" do
    matcher = build_matcher([ "Groceries", "Food & Drink", "Transportation" ])

    assert_equal "Groceries", matcher.match(5411)&.name
    assert_equal "Food & Drink", matcher.match(5812)&.name
    assert_equal "Transportation", matcher.match(5541)&.name
  end

  test "matches ranges as well as single codes" do
    matcher = build_matcher([ "Travel" ])

    assert_equal "Travel", matcher.match(3005)&.name, "airline MCCs are a range"
    assert_equal "Travel", matcher.match(7011)&.name, "hotels are a single code"
  end

  test "returns nil for MCCs with no confident mapping" do
    matcher = build_matcher([ "Groceries", "Shopping", "Fees" ])

    assert_nil matcher.match(6011), "ATM withdrawal is money movement, not spending"
    assert_nil matcher.match(4829), "money transfer is money movement"
    assert_nil matcher.match(7995), "gambling has no honest default category"
    assert_nil matcher.match(nil)
    assert_nil matcher.match("")
  end

  test "returns nil when the family has no equivalent category" do
    matcher = build_matcher([ "Shopping" ])

    assert_nil matcher.match(5411)
  end

  # A Ukrainian family's categories are named in Ukrainian, which is the whole reason
  # this matcher resolves the default category name in the family's own locale.
  test "matches localized default category names" do
    localized = I18n.t("models.category.defaults.groceries", locale: :uk)
    matcher = build_matcher([ localized ], locale: "uk")

    assert_equal localized, matcher.match(5411)&.name
  end

  test "ignores case, punctuation and the and conjunction" do
    matcher = build_matcher([ "gifts and donations" ])

    assert_equal "gifts and donations", matcher.match(8398)&.name
  end

  private

    def build_matcher(names, locale: nil)
      categories = names.each_with_index.map { |name, index| Category.new(index + 1, name) }

      MonobankAccount::Transactions::CategoryMatcher.new(categories, locale: locale)
    end
end
