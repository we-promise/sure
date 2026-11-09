# frozen_string_literal: true

require "test_helper"

class TricountAccount::Transactions::CategoryMatcherTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @food = @family.categories.create!(name: "Food & Drink", color: "#000000")
    @groceries = @family.categories.create!(name: "Groceries", color: "#000000")
    @transport = @family.categories.create!(name: "Transportation", color: "#000000")
    @matcher = TricountAccount::Transactions::CategoryMatcher.new(@family.categories.to_a)
  end

  test "Tricount's categories match the family's by name and alias" do
    assert_equal @food, @matcher.match("FOOD_AND_DRINK")
    assert_equal @groceries, @matcher.match("GROCERIES")
    assert_equal @transport, @matcher.match("TRANSPORT")
  end

  test "a custom label matches a category of the same name" do
    assert_equal @groceries, @matcher.match("groceries")
  end

  test "a category with no match among the family's is left unset" do
    assert_nil @matcher.match("ENTERTAINMENT")
    assert_nil @matcher.match("Market")
    assert_nil @matcher.match(nil)
  end
end
