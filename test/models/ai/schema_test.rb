require "test_helper"

class Ai::SchemaTest < ActiveSupport::TestCase
  BILL = {
    type: "object",
    properties: {
      name: { type: %w[string null] },
      amount: { type: %w[number null] },
      day_of_month: { type: %w[integer null], minimum: 1, maximum: 31 },
      bill_type: { type: %w[string null], enum: [ "bill", "subscription", nil ] },
      autopay: { type: %w[boolean null] }
    },
    required: %w[name amount day_of_month bill_type autopay],
    additionalProperties: false
  }.freeze

  LIST = {
    type: "object",
    properties: {
      categorizations: {
        type: "array",
        items: {
          type: "object",
          properties: {
            transaction_id: { type: "string" },
            category_name: { type: %w[string null], enum: [ "Coffee", "Salary", "null", nil ] }
          },
          required: %w[transaction_id category_name],
          additionalProperties: false
        }
      }
    },
    required: %w[categorizations],
    additionalProperties: false
  }.freeze

  test "nulls, numeric strings, enums and ranges are coerced" do
    value = Ai::Schema.coerce({ "name" => "null", "amount" => "15.99", "day_of_month" => "40", "bill_type" => "weird",
                                "autopay" => "yes" }, BILL)

    assert_equal({ name: nil, amount: 15.99, day_of_month: nil, bill_type: nil, autopay: nil }, value)
    assert_equal 12, Ai::Schema.coerce({ "day_of_month" => 12.0 }, BILL)[:day_of_month]
    assert_equal false, Ai::Schema.coerce({ "autopay" => false }, BILL)[:autopay]
  end

  test "items take aliased keys, a bare array or another wrapper, and drop what can't be matched" do
    aliases = { categorizations: %w[results], transaction_id: %w[id txn_id], category_name: %w[category name] }
    answer = [ { "id" => "t1", "category" => "Coffee" }, { "txn_id" => 7, "name" => "null" }, { "category" => "Salary" }, "junk" ]

    from_array = Ai::Schema.coerce(answer, LIST, aliases:, required: %i[transaction_id])
    from_wrapper = Ai::Schema.coerce({ "results" => answer }, LIST, aliases:, required: %i[transaction_id])

    expected = [ { transaction_id: "t1", category_name: "Coffee" }, { transaction_id: "7", category_name: nil } ]
    assert_equal expected, from_array[:categorizations]
    assert_equal expected, from_wrapper[:categorizations]
  end

  test "a field the generation matches itself skips the enum" do
    match = { category_name: ->(name) { name.downcase.start_with?("coffee") ? "Coffee" : nil } }

    value = Ai::Schema.coerce({ "categorizations" => [ { "transaction_id" => "t1", "category_name" => "coffee shops" } ] }, LIST, match:)

    assert_equal "Coffee", value[:categorizations].first[:category_name]
  end

  test "an answer that isn't an object, or lacks its list, is invalid output" do
    assert_raises(Ai::Error::InvalidOutput) { Ai::Schema.coerce("text", BILL) }
    assert_raises(Ai::Error::InvalidOutput) { Ai::Schema.coerce({ "something" => [] }, LIST) }
  end

  test "a number too large for a float is nil, not an error" do
    value = Ai::Schema.coerce(JSON.parse('{"name": "Gym", "amount": 1e400, "day_of_month": 1e400, "bill_type": null, "autopay": null}'), BILL)

    assert_nil value[:amount]
    assert_nil value[:day_of_month]
  end

  test "an object with none of the schema's fields is invalid output; explicit nulls aren't" do
    assert_raises(Ai::Error::InvalidOutput) { Ai::Schema.coerce({ "error" => "unable to analyze" }, BILL) }

    nulls = { "name" => nil, "amount" => nil, "day_of_month" => nil, "bill_type" => nil, "autopay" => nil }
    assert_equal({ name: nil, amount: nil, day_of_month: nil, bill_type: nil, autopay: nil }, Ai::Schema.coerce(nulls, BILL))
  end
end
