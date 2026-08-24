require "test_helper"

class TradeRepublicAccountCategoryMatcherTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.categories.create!(name: "Subscriptions")
    @shopping = @family.categories.create!(name: "Shopping")
    @matcher = TradeRepublicAccount::CategoryMatcher.new(@family)
  end

  test "matches Amazon Prime as a subscription without classifying plain Amazon as one" do
    subscriptions = @family.categories.find_by!(name: "Subscriptions")

    assert_equal subscriptions, @matcher.category_for("Amazon Prime")
    assert_equal @shopping, @matcher.category_for("Amazon Marketplace")
  end
end
