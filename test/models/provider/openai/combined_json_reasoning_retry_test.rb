require "test_helper"

class Provider::Openai::CombinedJsonReasoningRetryTest < ActiveSupport::TestCase
  OPERATIONS = %i[auto_categorize auto_detect_merchants].freeze

  setup do
    @client = mock
    @requests = []
    Setting.stubs(:openai_reasoning_effort).returns("low")
  end

  OPERATIONS.each do |operation|
    %i[malformed_json invalid_shape].each do |failure|
      test "#{operation} auto retries #{failure} with reasoning effort retained" do
        @client.expects(:chat).twice
          .with { |args| @requests << args[:parameters]; true }
          .returns(chat_response(invalid_content(operation, failure)))
          .then
          .returns(chat_response(valid_content(operation)))

        result = call_extractor(operation)

        assert_equal [ result_attributes(operation) ], result.map(&:to_h)
        assert_retry(with_reasoning_effort: true)
      end
    end

    test "#{operation} auto accepts valid strict output with reasoning effort" do
      @client.expects(:chat).once
        .with { |args| @requests << args[:parameters]; true }
        .returns(chat_response(valid_content(operation)))

      result = call_extractor(operation)

      assert_equal [ result_attributes(operation) ], result.map(&:to_h)
      assert_equal 1, @requests.size
      assert_strict_request
    end

    test "#{operation} auto propagates a JSON fallback 400 without a third request" do
      fallback_error = Faraday::BadRequestError.new("JSON fallback rejected")
      @client.expects(:chat).twice
        .with { |args| @requests << args[:parameters]; true }
        .returns(chat_response(invalid_content(operation, :malformed_json)))
        .then
        .raises(fallback_error)

      error = assert_raises(Faraday::BadRequestError) do
        call_extractor(operation)
      end

      assert_same fallback_error, error
      assert_retry(with_reasoning_effort: true)
    end

    test "#{operation} auto propagates an invalid JSON fallback shape without a third request" do
      @client.expects(:chat).twice
        .with { |args| @requests << args[:parameters]; true }
        .returns(chat_response(invalid_content(operation, :malformed_json)))
        .then
        .returns(chat_response(invalid_content(operation, :invalid_shape)))

      error = assert_raises(Provider::Openai::ResponseFormatError) do
        call_extractor(operation)
      end

      assert_equal "Could not find #{response_key(operation)} in response", error.message
      assert_retry(with_reasoning_effort: true)
    end

    %w[strict auto].each do |mode|
      test "#{operation} #{mode} propagates malformed output after a 400 compatibility retry" do
        @client.expects(:chat).twice
          .with { |args| @requests << args[:parameters]; true }
          .raises(Faraday::BadRequestError, "strict request rejected")
          .then
          .returns(chat_response(invalid_content(operation, :malformed_json)))

        error = assert_raises(Provider::Openai::ResponseFormatError) do
          call_extractor(operation, mode: mode)
        end

        assert_match(/Could not parse JSON from response/, error.message)
        assert_retry(with_reasoning_effort: false)
      end
    end

    test "#{operation} auto retains reasoning effort when ID filtering leaves missing results" do
      idless_content = json_content(operation, [ result_attributes(operation).except(:transaction_id) ])
      @client.expects(:chat).twice
        .with { |args| @requests << args[:parameters]; true }
        .returns(chat_response(idless_content))
        .then
        .returns(chat_response(valid_content(operation)))

      result = call_extractor(operation)

      assert_equal [ result_attributes(operation) ], result.map(&:to_h)
      assert_retry(with_reasoning_effort: true)
    end
  end

  %i[business_name business_url].each do |missing_field|
    test "merchant detection auto retains reasoning effort when #{missing_field} is missing" do
      operation = :auto_detect_merchants
      partial_content = json_content(operation, [ result_attributes(operation).except(missing_field) ])
      @client.expects(:chat).twice
        .with { |args| @requests << args[:parameters]; true }
        .returns(chat_response(partial_content))
        .then
        .returns(chat_response(valid_content(operation)))

      result = call_extractor(operation)

      assert_equal [ result_attributes(operation) ], result.map(&:to_h)
      assert_retry(with_reasoning_effort: true)
    end
  end

  private

    def call_extractor(operation, mode: "auto")
      options = { model: "test-model", custom_provider: true, json_mode: mode }
      transactions = [ { id: "txn_1", name: "McDonalds", amount: 20, classification: "expense" } ]

      extractor = case operation
      when :auto_categorize
        Provider::Openai::AutoCategorizer.new(
          @client, **options, transactions: transactions,
          user_categories: [ { id: "cat_1", name: "Food", is_subcategory: false, parent_id: nil, classification: "expense" } ]
        )
      when :auto_detect_merchants
        Provider::Openai::AutoMerchantDetector.new(
          @client, **options, transactions: transactions,
          user_merchants: [ { id: "merchant_1", name: "McDonalds" } ]
        )
      end

      with_env_overrides("OPENAI_REASONING_EFFORT" => nil) do
        extractor.public_send(operation)
      end
    end

    def result_attributes(operation)
      if operation == :auto_categorize
        { transaction_id: "txn_1", category_name: "Food" }
      else
        { transaction_id: "txn_1", business_name: "McDonalds", business_url: "mcdonalds.com" }
      end
    end

    def response_key(operation)
      operation == :auto_categorize ? "categorizations" : "merchants"
    end

    def json_content(operation, rows)
      { response_key(operation) => rows }.to_json
    end

    def valid_content(operation)
      json_content(operation, [ result_attributes(operation) ])
    end

    def invalid_content(operation, failure)
      failure == :malformed_json ? '{"broken":' : json_content(operation, [ "invalid" ])
    end

    def chat_response(content)
      {
        "choices" => [ { "message" => { "content" => content } } ],
        "usage" => { "total_tokens" => 1 }
      }
    end

    def assert_strict_request
      assert_equal "json_schema", @requests.first.dig(:response_format, :type)
      assert_equal true, @requests.first.dig(:response_format, :json_schema, :strict)
      assert_equal "low", @requests.first[:reasoning_effort]
    end

    def assert_retry(with_reasoning_effort:)
      assert_equal 2, @requests.size
      assert_strict_request
      assert_not @requests.second.key?(:response_format)

      if with_reasoning_effort
        assert_equal "low", @requests.second[:reasoning_effort]
        assert_equal @requests.first.except(:response_format), @requests.second
      else
        assert_not @requests.second.key?(:reasoning_effort)
        assert_equal @requests.first.except(:response_format, :reasoning_effort), @requests.second
      end
    end
end
