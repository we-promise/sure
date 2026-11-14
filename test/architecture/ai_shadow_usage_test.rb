require "test_helper"

# A shadow run through the real transport stack (RubyLLM + WebMock):
# the shadow's llm_usages rows say shadow_categorize and carry the shadow
# flag; the primary's trip neither.
class AiShadowUsageTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include ActiveJob::TestHelper

  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  RESPONSES_URL = "https://api.openai.com/v1/responses".freeze
  JEV_URL = "https://api.typesafe.ai/v1/systemone".freeze

  setup do
    @family = families(:dylan_family)
    @family.update!(categorization_shadow_rate: 1.0)
    @account = @family.accounts.create!(name: "Shadow usage", balance: 0, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Coffee")
    @txn = create_transaction(account: @account, name: "Blue Bottle").transaction
    use_ai_routes
  end

  test "the shadow's usage rows are its own, tagged shadow; the primary's stay plain" do
    responses_ok(@category, @txn.id)
    jev_ok(@category)

    perform_enqueued_jobs { Ai::GenerationJob.perform_now(:categorize, { ids: [ @txn.id ], family_id: @family.id }) }

    primary = @family.llm_usages.where(operation: "categorize")
    shadow = @family.llm_usages.where(operation: "shadow_categorize")
    assert primary.any?, "the OpenAI call wrote a usage row"
    assert shadow.any?, "the Jev shadow call wrote a usage row"
    assert shadow.all? { _1.metadata["shadow"] == true }, "shadow rows carry the shadow flag: #{shadow.map(&:metadata).inspect}"
    assert primary.none? { _1.metadata.key?("shadow") }, "primary rows are untagged"
    assert shadow.sole.provider == "jev"
  end

  private
    def responses_ok(category, txn_id)
      body = {
        id: "resp_1", object: "response", status: "completed",
        output: [
          { type: "message", id: "msg_1", status: "completed", role: "assistant",
            content: [ { type: "output_text",
                         text: { categorizations: [ { transaction_id: txn_id, category_name: category.name } ] }.to_json,
                         annotations: [] } ] }
        ],
        usage: { input_tokens: 20, output_tokens: 6, total_tokens: 26,
                 input_tokens_details: { cached_tokens: 5 }, output_tokens_details: { reasoning_tokens: 0 } },
        model: "gpt-4.1-mini"
      }
      stub_request(:post, RESPONSES_URL).to_return(status: 200, headers: JSON_HEADERS, body: body.to_json)
    end

    def jev_ok(category)
      body = {
        model: "jev-latest",
        answers: { category: { type: "choice", choice: category.name,
                               probabilities: { category.name => 0.92, "__uncategorized__" => 0.08 }, confidence: 0.92 } },
        usage: { input_tokens: 120, output_tokens: 0 }
      }
      stub_request(:post, JEV_URL).to_return(status: 200, headers: JSON_HEADERS, body: body.to_json)
    end
end
