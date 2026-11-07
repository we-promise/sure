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

  test "the model's other field names and a bare list are accepted, as today" do
    value = coerce([ { "id" => "t1", "category" => "Restaurants" }, { "category" => "Restaurants" } ])

    assert_equal [ { transaction_id: "t1", category_name: "Restaurants" } ], value[:categorizations]
  end

  test "the enum lists the batch's ids and the family's names, with null both ways" do
    schema = Ai::Generations::CategorizeTransactions.new(transactions: [ { id: "t1" } ], categories: CATEGORIES, family: nil).schema
    item = schema.dig(:properties, :categorizations, :items, :properties)

    assert_equal %w[t1], item.dig(:transaction_id, :enum)
    assert_equal [ "Restaurants", "Coffee Shops", "Gas & Fuel", "null", nil ], item.dig(:category_name, :enum)
  end
end
