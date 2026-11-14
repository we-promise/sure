# Detects the business behind each transaction (name and website) from its description, using
# the family's own merchants where one matches. Replaces
# Provider::{Openai,Anthropic}::AutoMerchantDetector.
class Ai::Generations::DetectMerchants < Ai::Generation
  feature :detect_merchants
  prompt "detect_merchants"
  schema_name "auto_detect_personal_finance_merchants"
  batch :transactions
  merge :merchants, by: :transaction_id
  required :transaction_id
  aliases merchants: %w[results], transaction_id: %w[id txn_id], business_name: %w[name merchant_name merchant],
          business_url: %w[url website]
  # An answer without both a name and a website is a failed one.
  blank_item { _1[:business_name].blank? || _1[:business_url].blank? }

  # transactions: [{ id:, amount:, classification:, description:, merchant: }];
  # merchants: the family's own, [{ id:, name: }].
  def initialize(transactions:, merchants:, family:)
    super(family:)
    @transactions, @merchants = transactions, merchants
  end

  def prompt_locals = { transactions: items, merchants: @merchants }

  # A name matching one of the family's merchants, case aside, takes that merchant's spelling.
  def matchers
    { business_name: ->(name) { @merchants.find { _1[:name].to_s.casecmp?(name) }&.dig(:name) || name } }
  end

  def schema
    {
      type: "object",
      properties: {
        merchants: {
          type: "array",
          description: "An array of auto-detected merchant businesses for each transaction",
          items: {
            type: "object",
            properties: {
              transaction_id: { type: "string", description: "The internal ID of the original transaction", enum: items.map { _1[:id].to_s } },
              business_name: { type: %w[string null], description: "The detected business name of the transaction, or `null` if uncertain" },
              business_url: { type: %w[string null], description: "The URL of the detected business, or `null` if uncertain" }
            },
            required: %w[transaction_id business_name business_url],
            additionalProperties: false
          }
        }
      },
      required: %w[merchants],
      additionalProperties: false
    }
  end
end
