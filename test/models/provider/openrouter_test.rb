require "test_helper"

class Provider::OpenrouterTest < ActiveSupport::TestCase
  setup do
    @model = "openai/gpt-4.1-mini"
    @provider = Provider::Openrouter.new("synthetic-family-key", model: @model)
  end

  test "family OpenRouter uses only its fixed endpoint model and key" do
    options = Provider::Openai.family_client_options.merge(
      access_token: "synthetic-family-key", uri_base: Provider::Openrouter::ENDPOINT,
      request_timeout: Provider::Openrouter.request_timeout
    )
    with_env_overrides(
      "OPENAI_URI_BASE" => "https://operator.example/v1", "OPENAI_MODEL" => "operator-model",
      "OPENAI_EXTRA_HEADERS" => '{"Authorization":"Bearer operator-secret"}',
      "OPENAI_SUPPORTS_RESPONSES_ENDPOINT" => "true"
    ) do
      Provider::Openrouter.expects(:extra_headers).never
      Provider::Openrouter.expects(:effective_model).never
      ::OpenAI::Client.expects(:new).with(**options).returns(mock)

      provider = Provider::Openrouter.new("synthetic-family-key", model: @model)
      assert_equal "OpenRouter", provider.provider_name
      assert_equal @model, provider.default_model
      assert provider.custom_provider?
      assert provider.supports_model?(@model)
      assert_not provider.supports_model?("anthropic/claude-sonnet-4")
      assert_not provider.supports_responses_endpoint?
    end
  end

  test "model IDs must be explicit catalog slugs rather than URLs or request fragments" do
    [ nil, "", "gpt-4.1", "https://example.com/model", "openai/gpt-4.1\n", "openai/model?key=secret", "a/" + "b" * 255 ].each do |model|
      assert_raises(Provider::Openai::Error) { Provider::Openrouter.new("synthetic-key", model: model) }
    end
    assert Provider::Openrouter.valid_model_id?("meta-llama/llama-3.3-70b-instruct:free")
  end

  test "OpenRouter sends chat history and tool rounds through generic completions" do
    history = [ { role: "user", content: "Earlier" }, { role: "assistant", content: "Reply" }, { role: "user", content: "Now" } ]
    rounds = [ { call_id: "call_one", name: "get_accounts", arguments: "{}", output: {}, round: 1 },
               { call_id: "call_two", name: "get_categories", arguments: "{}", output: {}, round: 2 } ]
    @provider.stubs(:max_history_tokens).returns(10_000)
    @provider.stubs(:explicit_max_response_tokens).returns(nil)
    request = stub_request(:post, "#{Provider::Openrouter::ENDPOINT}/chat/completions")
      .with do |outbound|
        payload = JSON.parse(outbound.body)
        outbound.headers["Authorization"] == "Bearer synthetic-family-key" &&
          payload["model"] == @model && payload["messages"].first(3) == history.as_json &&
          payload["messages"].filter_map { |message| message["tool_call_id"] } == %w[call_one call_two] &&
          !payload.key?("previous_response_id")
      end.to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "router-response", model: @model, choices: [ { message: { role: "assistant", content: "OK" } } ]
      }.to_json)

    response = @provider.chat_response("Now", model: @model, messages: history, function_results: rounds,
                                       previous_response_id: "other-account-response")

    assert response.success?
    assert_requested request
    assert_not_requested :post, %r{/responses\z}
  end

  test "PDF analysis extracts text without assuming native OpenAI or image support" do
    processor = mock("text PDF processor")
    result = stub("PDF result")
    @provider.stubs(:max_response_tokens).returns(512)
    Provider::Openai::PdfProcessor.expects(:new).with do |client, **options|
      client.uri_base == Provider::Openrouter::ENDPOINT && options[:model] == @model &&
        options[:custom_provider] && options[:processing_mode] == :text && options[:pdf_content] == "synthetic PDF" && options[:json_mode] == "none"
    end.returns(processor)
    processor.expects(:process).returns(result)

    assert @provider.supports_pdf_processing?
    assert_not @provider.supports_pdf_processing?(model: "gpt-6-sol")
    assert_same result, @provider.process_pdf(pdf_content: "synthetic PDF").data
  end

  test "text statement extraction does not inherit installation structured output settings" do
    extractor = mock("statement extractor")
    Provider::Openai::BankStatementExtractor.expects(:new).with do |**options|
      options[:client].uri_base == Provider::Openrouter::ENDPOINT && options[:model] == @model &&
        options[:pdf_content] == "synthetic PDF" && options[:json_mode] == "none"
    end.returns(extractor)
    extractor.expects(:extract).returns(transactions: [])

    with_env_overrides("LLM_JSON_MODE" => "strict") do
      assert @provider.extract_bank_statement(pdf_content: "synthetic PDF").success?
    end
  end

  test "blank or scanned PDF text fails without sending page markers or images to a model" do
    Pdf::TextExtractor.expects(:pages).with("synthetic scanned PDF").returns([ "", "  " ])
    @provider.stubs(:max_response_tokens).returns(512)
    response = @provider.process_pdf(pdf_content: "synthetic scanned PDF")

    assert_not response.success?
    assert_match(/Could not extract text/, response.error.message)
    assert_not_requested :post, %r{https://openrouter.ai/}
  end
end
