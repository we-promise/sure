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

  test "a number too large for a float is nil, not an error" do
    value = Ai::Schema.coerce(JSON.parse('{"name": "Gym", "amount": 1e400, "day_of_month": 1e400, "bill_type": null, "autopay": null}'), BILL)

    assert_nil value[:amount]
    assert_nil value[:day_of_month]
  end

  test "an object with none of the schema's fields is invalid output; explicit nulls aren't" do
    assert_raises(Ai::Error::InvalidOutput) { Ai::Schema.coerce({ "error" => "unable to analyze" }, BILL) }
    assert_raises(Ai::Error::InvalidOutput) { Ai::Schema.coerce({}, BILL) }

    nulls = { "name" => nil, "amount" => nil, "day_of_month" => nil, "bill_type" => nil, "autopay" => nil }
    assert_equal({ name: nil, amount: nil, day_of_month: nil, bill_type: nil, autopay: nil }, Ai::Schema.coerce(nulls, BILL))
  end
end
