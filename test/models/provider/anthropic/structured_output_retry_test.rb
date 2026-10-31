require "test_helper"
require "ostruct"

# The `auto` path (models that reject a forced tool_choice) may get a text-only
# end_turn answer. All six structured-output helpers retry that once.
class Provider::Anthropic::StructuredOutputRetryTest < ActiveSupport::TestCase
  PDF = "%PDF-1.4 fake bytes".b
  AUTO_MODEL = "claude-sonnet-5-5"

  HELPERS = {
    "report_categorizations" => {
      input: { "categorizations" => [ { "transaction_id" => "txn_1", "category_name" => "Fast Food" } ] },
      build: ->(client, family) {
        Provider::Anthropic::AutoCategorizer.new(client, model: AUTO_MODEL, family: family,
          transactions: [ { id: "txn_1", name: "McDonalds", amount: 20 } ], user_categories: [ { id: "c1", name: "Fast Food" } ]).auto_categorize
      },
      check: ->(test, result) { test.assert_equal "Fast Food", result.first.category_name }
    },
    "report_merchants" => {
      input: { "merchants" => [ { "transaction_id" => "txn_1", "business_name" => "Amazon", "business_url" => "amazon.com" } ] },
      build: ->(client, family) {
        Provider::Anthropic::AutoMerchantDetector.new(client, model: AUTO_MODEL, family: family,
          transactions: [ { id: "txn_1", name: "AMZN" } ], user_merchants: []).auto_detect_merchants
      },
      check: ->(test, result) { test.assert_equal "Amazon", result.first.business_name }
    },
    "report_enhancements" => {
      input: { "merchants" => [ { "merchant_id" => "m1", "business_url" => "walmart.com" } ] },
      build: ->(client, family) {
        Provider::Anthropic::ProviderMerchantEnhancer.new(client, model: AUTO_MODEL, family: family,
          merchants: [ { id: "m1", name: "Walmart" } ]).enhance_merchants
      },
      check: ->(test, result) { test.assert_equal "walmart.com", result.first.business_url }
    },
    "report_bill_setup" => {
      input: { "name" => "Netflix", "amount" => 15.49, "frequency" => "monthly", "day_of_month" => 3,
               "category_name" => "Subscriptions", "bill_type" => "subscription", "confidence" => 0.9 },
      build: ->(client, family) {
        Provider::Anthropic::BillSetupSuggester.new(client, model: AUTO_MODEL, family: family,
          charges: [ { date: "2026-08-03", amount: 15.49, name: "NETFLIX.COM" } ], categories: [ "Subscriptions" ]).suggest
      },
      check: ->(test, result) { test.assert_equal "Netflix", result.name }
    },
    "report_document_analysis" => {
      input: { "document_type" => "bank_statement", "summary" => "Statement" },
      build: ->(client, family) {
        Provider::Anthropic::PdfProcessor.new(client, model: AUTO_MODEL, family: family, pdf_content: PDF).process
      },
      check: ->(test, result) { test.assert_equal "Statement", result.summary }
    },
    "report_bank_statement" => {
      input: { "bank_name" => "Bank of Example", "transactions" => [ { "date" => "2026-03-05", "description" => "Coffee", "amount" => -4.5 } ] },
      build: ->(client, family) {
        Provider::Anthropic::BankStatementExtractor.new(client: client, model: AUTO_MODEL, family: family, pdf_content: PDF).extract
      },
      check: ->(test, result) { test.assert_equal 1, result[:transactions].size }
    }
  }.freeze

  setup do
    @family = families(:dylan_family)
  end

  HELPERS.each do |tool_name, helper|
    test "#{tool_name}: retries once after a text-only end_turn and records usage for both calls" do
      requests = []
      client = stub_client(requests, [ text_response("Looks like groceries."), tool_response(tool_name, helper[:input]) ])

      result = nil
      assert_difference -> { @family.llm_usages.count }, 2 do
        result = helper[:build].call(client, @family)
      end

      helper[:check].call(self, result)
      assert_equal 2, requests.size
      assert_equal({ type: "auto", disable_parallel_tool_use: true }, requests.last[:tool_choice])
      retry_messages = requests.last[:messages]
      assert_equal requests.first[:messages], retry_messages.first(requests.first[:messages].size)
      assert_equal [ "assistant", "user" ], retry_messages.last(2).map { |m| m[:role] }
      assert_equal "Looks like groceries.", retry_messages[-2][:content]
      assert_includes retry_messages.last[:content], tool_name
    end

    test "#{tool_name}: raises after a second missing tool call and records both billed attempts" do
      requests = []
      client = stub_client(requests, [ text_response("No."), text_response("Still no.") ])

      err = nil
      # two billed calls plus the zero-token error row the helpers always write
      assert_difference -> { @family.llm_usages.count }, 3 do
        err = assert_raises(Provider::Anthropic::Error) { helper[:build].call(client, @family) }
      end

      assert_match(/did not invoke #{tool_name} \(stop_reason: end_turn\)/, err.message)
      assert_equal 2, requests.size
    end

    test "#{tool_name}: does not retry when the first response has the tool call" do
      requests = []
      client = stub_client(requests, [ tool_response(tool_name, helper[:input]) ])

      assert_difference -> { @family.llm_usages.count }, 1 do
        helper[:build].call(client, @family)
      end

      assert_equal 1, requests.size
    end

    %w[max_tokens refusal].each do |reason|
      test "#{tool_name}: does not retry on #{reason}" do
        requests = []
        client = stub_client(requests, [ text_response("partial", stop_reason: reason) ])

        assert_raises(Provider::Anthropic::Error) { helper[:build].call(client, @family) }
        assert_equal 1, requests.size
      end
    end
  end

  test "does not retry on the forced tool path" do
    requests = []
    client = stub_client(requests, [ text_response("No.") ])

    assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::AutoCategorizer.new(client, model: "claude-haiku-4-5", family: @family,
        transactions: [ { id: "txn_1", name: "McDonalds", amount: 20 } ], user_categories: []).auto_categorize
    end

    assert_equal 1, requests.size
    assert_equal "tool", requests.first[:tool_choice][:type]
  end

  test "the retry without any text in the first answer only adds the reminder" do
    requests = []
    response = OpenStruct.new(content: [], stop_reason: :end_turn, usage: OpenStruct.new(input_tokens: 5, output_tokens: 0))
    client = stub_client(requests, [ response, tool_response("report_categorizations", HELPERS["report_categorizations"][:input]) ])

    HELPERS["report_categorizations"][:build].call(client, @family)

    assert_equal [ "user", "user" ], requests.last[:messages].map { |m| m[:role] }
  end

  private
    def stub_client(requests, responses)
      messages = mock
      messages.stubs(:create).with { |params| requests << Marshal.load(Marshal.dump(params)); true }.returns(*responses)
      client = mock
      client.stubs(:messages).returns(messages)
      client
    end

    def text_response(text, stop_reason: "end_turn")
      OpenStruct.new(content: [ OpenStruct.new(type: :text, text: text) ], stop_reason: stop_reason, usage: usage)
    end

    def tool_response(name, input)
      OpenStruct.new(content: [ OpenStruct.new(type: :tool_use, id: "toolu_1", name: name, input: input) ], stop_reason: "tool_use", usage: usage)
    end

    def usage
      OpenStruct.new(input_tokens: 50, output_tokens: 25)
    end
end
