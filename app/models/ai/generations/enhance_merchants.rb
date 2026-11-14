# Finds the website of each of a family's provider merchants that has none, so a logo can be
# generated from it. Replaces Provider::{Openai,Anthropic}::ProviderMerchantEnhancer.
class Ai::Generations::EnhanceMerchants < Ai::Generation
  feature :enhance_merchants
  prompt "enhance_merchants"
  schema_name "enhance_provider_merchants"
  batch :merchants
  merge :merchants, by: :merchant_id
  required :merchant_id
  aliases merchants: %w[results], merchant_id: %w[id], business_url: %w[url website]
  blank_item { _1[:business_url].nil? }

  # merchants: [{ id:, name: }]
  def initialize(merchants:, family:)
    super(family:)
    @merchants = merchants
  end

  def prompt_locals = { merchants: items }

  def schema
    {
      type: "object",
      properties: {
        merchants: {
          type: "array",
          description: "An array of merchant website detections",
          items: {
            type: "object",
            properties: {
              merchant_id: { type: "string", description: "The internal ID of the merchant", enum: items.map { _1[:id].to_s } },
              business_url: { type: %w[string null], description: "The website URL of the business, or `null` if uncertain" }
            },
            required: %w[merchant_id business_url],
            additionalProperties: false
          }
        }
      },
      required: %w[merchants],
      additionalProperties: false
    }
  end
end
