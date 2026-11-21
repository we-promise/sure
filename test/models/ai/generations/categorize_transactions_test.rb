require "test_helper"

class Ai::Generations::CategorizeTransactionsTest < ActiveSupport::TestCase
  CATEGORIES = [
    { id: "c1", name: "Restaurants" }, { id: "c2", name: "Coffee Shops" }, { id: "c3", name: "Gas & Fuel" }
  ].freeze

  def coerce(answer)
    Ai::Generations::CategorizeTransactions.new(transactions: [ { id: "t1" } ], categories: CATEGORIES, family: nil).coerce(answer)
  end

  def name_for(model_answer) = coerce({ "categorizations" => [ { "transaction_id" => "t1", "category_name" => model_answer } ] })[:categorizations].first[:category_name]

  test "a model's category name maps onto the family's spelling: exact, case aside, or fuzzy" do
    assert_equal "Restaurants", name_for("Restaurants")
    assert_equal "Coffee Shops", name_for("coffee shops")
    assert_equal "Coffee Shops", name_for("Coffee Shop")
    assert_equal "Gas & Fuel", name_for("fuel")
    assert_nil name_for("Groceries")
    assert_nil name_for("null")
    assert_nil name_for("@@")
  end

  test "a short category isn't matched inside a longer answer, and the longest contained name wins" do
    generation = Ai::Generations::CategorizeTransactions.new(transactions: [ { id: "t1" } ], family: nil,
                                                             categories: [ { id: "c1", name: "Car" }, { id: "c2", name: "Health" } ])
    name = ->(answer) { generation.coerce({ "categorizations" => [ { "transaction_id" => "t1", "category_name" => answer } ] })[:categorizations].first[:category_name] }

    assert_equal "Health", name.("Healthcare")
    assert_nil name.("Carpet cleaning")
    assert_equal "Car", name.("car")
  end

  test "a family category with no ASCII letters isn't a fuzzy match for every unknown name" do
    generation = Ai::Generations::CategorizeTransactions.new(transactions: [ { id: "t1" } ], family: nil,
                                                             categories: [ { id: "c1", name: "食品" }, { id: "c2", name: "Restaurants" } ])
    value = generation.coerce({ "categorizations" => [ { "transaction_id" => "t1", "category_name" => "Groceries" } ] })

    assert_nil value[:categorizations].first[:category_name]
  end
end
