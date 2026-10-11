require "test_helper"

class Provider::Openai::GenericReasoningRetryTest < ActiveSupport::TestCase
  OPERATIONS = %i[auto_categorize auto_detect_merchants enhance_merchants].freeze

  setup do
    @client = mock
    @requests = []
    Setting.stubs(:openai_reasoning_effort).returns("low")
  end

  OPERATIONS.each do |operation|
    %w[strict auto].each do |mode|
      test "#{operation} #{mode} 400 retries without response format or reasoning effort" do
        @client.expects(:chat).twice
          .with { |args| @requests << args[:parameters]; true }
          .raises(Faraday::BadRequestError, "strict request rejected")
          .then
          .returns(chat_response(operation))

        result = call_extractor(operation, mode: mode)

        assert_equal [ result_attributes(operation) ], result.map(&:to_h)
        assert_compatibility_retry
      end

      test "#{operation} #{mode} propagates a second 400 without a third request" do
        fallback_error = Faraday::BadRequestError.new("fallback request rejected")
        @client.expects(:chat).twice
          .with { |args| @requests << args[:parameters]; true }
          .raises(Faraday::BadRequestError, "strict request rejected")
          .then
          .raises(fallback_error)

        error = assert_raises(Faraday::BadRequestError) do
          call_extractor(operation, mode: mode)
        end

        assert_same fallback_error, error
        assert_compatibility_retry
      end
    end

    %i[null missing].each do |quality|
      test "#{operation} auto retains reasoning effort when retrying #{quality} results" do
        @client.expects(:chat).twice
          .with { |args| @requests << args[:parameters]; true }
          .returns(chat_response(operation, quality: quality))
          .then
          .returns(chat_response(operation))

        result = call_extractor(operation, mode: "auto")

        assert_equal [ result_attributes(operation) ], result.map(&:to_h)
        assert_heuristic_retry
      end
    end

    test "#{operation} auto propagates a heuristic fallback 400 without a third request" do
      fallback_error = Faraday::BadRequestError.new("heuristic fallback rejected")
      @client.expects(:chat).twice
        .with { |args| @requests << args[:parameters]; true }
        .returns(chat_response(operation, quality: :null))
        .then
        .raises(fallback_error)

      error = assert_raises(Faraday::BadRequestError) do
        call_extractor(operation, mode: "auto")
      end

      assert_same fallback_error, error
      assert_heuristic_retry
    end

    %w[none json_object].each do |mode|
      test "#{operation} #{mode} propagates a 400 without retrying" do
        request_error = Faraday::BadRequestError.new("request rejected")
        @client.expects(:chat).once
          .with { |args| @requests << args[:parameters]; true }
          .raises(request_error)

        error = assert_raises(Faraday::BadRequestError) do
          call_extractor(operation, mode: mode)
        end

        assert_same request_error, error
        assert_equal 1, @requests.size
        assert_equal "low", @requests.first[:reasoning_effort]
        if mode == "json_object"
          assert_equal({ type: "json_object" }, @requests.first[:response_format])
        else
          assert_not @requests.first.key?(:response_format)
        end
      end
    end
  end

  private

    def call_extractor(operation, mode:)
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
      when :enhance_merchants
        Provider::Openai::ProviderMerchantEnhancer.new(
          @client, **options, merchants: [ { id: "merchant_1", name: "McDonalds" } ]
        )
      end

      with_env_overrides("OPENAI_REASONING_EFFORT" => nil) do
        extractor.public_send(operation)
      end
    end

    def result_attributes(operation, null: false)
      case operation
      when :auto_categorize
        { transaction_id: "txn_1", category_name: null ? "null" : "Food" }
      when :auto_detect_merchants
        { transaction_id: "txn_1", business_name: null ? "null" : "McDonalds", business_url: null ? "null" : "mcdonalds.com" }
      when :enhance_merchants
        { merchant_id: "merchant_1", business_url: null ? "null" : "mcdonalds.com" }
      end
    end

    def chat_response(operation, quality: :success)
      key = operation == :auto_categorize ? "categorizations" : "merchants"
      rows = quality == :missing ? [] : [ result_attributes(operation, null: quality == :null) ]

      {
        "choices" => [ { "message" => { "content" => { key => rows }.to_json } } ],
        "usage" => { "total_tokens" => 1 }
      }
    end

    def assert_strict_request
      assert_equal "json_schema", @requests.first.dig(:response_format, :type)
      assert_equal true, @requests.first.dig(:response_format, :json_schema, :strict)
      assert_equal "low", @requests.first[:reasoning_effort]
    end

    def assert_compatibility_retry
      assert_equal 2, @requests.size
      assert_strict_request
      assert_not @requests.second.key?(:response_format)
      assert_not @requests.second.key?(:reasoning_effort)
      assert_equal @requests.first.except(:response_format, :reasoning_effort), @requests.second
    end

    def assert_heuristic_retry
      assert_equal 2, @requests.size
      assert_strict_request
      assert_not @requests.second.key?(:response_format)
      assert_equal "low", @requests.second[:reasoning_effort]
      assert_equal @requests.first.except(:response_format), @requests.second
    end
end
