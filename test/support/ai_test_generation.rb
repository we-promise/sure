# A small batched generation for testing Ai::Generation itself, on detect_merchants' route and
# prompt folder.
class AiTestGeneration < Ai::Generation
  feature :detect_merchants
  prompt "detect_merchants_simple"
  schema_name "test_items"
  batch :transactions
  merge :merchants, by: :transaction_id
  required :transaction_id
  blank_item { _1[:business_name].nil? }

  SCHEMA = {
    type: "object",
    properties: {
      merchants: {
        type: "array",
        items: {
          type: "object",
          properties: { transaction_id: { type: "string" }, business_name: { type: %w[string null] }, business_url: { type: %w[string null] } },
          required: %w[transaction_id business_name business_url],
          additionalProperties: false
        }
      }
    },
    required: %w[merchants],
    additionalProperties: false
  }.freeze
  schema SCHEMA

  def initialize(transactions:, family:, **)
    super(family:, **)
    @transactions = transactions
  end

  def prompt_locals = { transactions: items, merchants: [] }

  # The answer a model gives for these transactions, as JSON.
  def self.answer(request, name: "Shop")
    ids = request.input.scan(/ID: (\S+),/).flatten
    { merchants: ids.map { { transaction_id: _1, business_name: name, business_url: "shop.test" } } }
  end
end
