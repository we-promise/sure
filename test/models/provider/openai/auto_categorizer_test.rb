require "test_helper"

class Provider::Openai::AutoCategorizerTest < ActiveSupport::TestCase
  setup do
    @client = mock
    @transactions = [
      { id: "1", name: "McDonalds", amount: 20, classification: "expense" }
    ]
    @user_categories = [
      { id: "cat1", name: "Food", is_subcategory: false, parent_id: nil, classification: "expense" }
    ]
  end

  test "auto mode retries without response_format when strict JSON cannot be parsed" do
    call_params = []
    @client.expects(:chat).twice
      .with { |args| call_params << args[:parameters]; true }
      .returns(
        chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"'),
        chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}')
      )

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal 1, result.size
    assert_equal "Food", result.first.category_name
    assert call_params.first[:response_format].present?, "strict attempt should send response_format"
    assert_nil call_params.second[:response_format], "retry should omit response_format"
  end

  test "auto mode retries when strict response parses but has the wrong shape" do
    @client.expects(:chat).twice
      .returns(
        chat_response('{"foo": []}'),
        chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}')
      )

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal "Food", result.first.category_name
  end

  test "auto mode accepts a top-level JSON array in a single call" do
    @client.expects(:chat).once
      .returns(chat_response('[{"transaction_id":"1","category_name":"Food"}]'))

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal "Food", result.first.category_name
  end

  test "auto mode retries when strict response is a JSON scalar" do
    @client.expects(:chat).twice
      .returns(
        chat_response("null"),
        chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}')
      )

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal "Food", result.first.category_name
  end

  test "auto mode retries when a recognized key holds a non-array value" do
    @client.expects(:chat).twice
      .returns(
        chat_response('{"categorizations": 5}'),
        chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}')
      )

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal "Food", result.first.category_name
  end

  test "auto mode does not fire a second fallback when the none-mode retry returns HTTP 400" do
    @client.expects(:chat).twice
      .returns(chat_response('{"categorizations":[{"transaction_id":"1"'))
      .then
      .raises(Faraday::BadRequestError.new("400"))

    assert_raises Faraday::BadRequestError do
      categorizer(json_mode: "auto").auto_categorize
    end
  end

  test "auto mode makes a single call when strict returns categorizations for all transactions" do
    @client.expects(:chat).once
      .returns(chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}'))

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal 1, result.size
    assert_equal "Food", result.first.category_name
  end

  test "strict mode raises ResponseFormatError on unparseable JSON without retrying" do
    @client.expects(:chat).once
      .returns(chat_response('{"categorizations":[{"transaction_id":"1"'))

    assert_raises Provider::Openai::ResponseFormatError do
      categorizer(json_mode: "strict").auto_categorize
    end
  end

  test "auto mode propagates network errors from the strict attempt" do
    @client.expects(:chat).once.raises(Faraday::TimeoutError.new("timeout"))

    assert_raises Faraday::TimeoutError do
      categorizer(json_mode: "auto").auto_categorize
    end
  end

  test "auto mode retries when every strict response item is malformed" do
    @client.expects(:chat).twice
      .returns(
        chat_response('{"categorizations":[{}]}'),
        chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}')
      )

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal "Food", result.first.category_name
  end

  test "auto mode drops malformed items below the retry threshold instead of returning nil fields" do
    @transactions.concat([
      { id: "2", name: "Shell", amount: 50, classification: "expense" },
      { id: "3", name: "Netflix", amount: 15, classification: "expense" },
      { id: "4", name: "Spotify", amount: 10, classification: "expense" }
    ])

    @client.expects(:chat).once
      .returns(chat_response(<<~JSON.squish))
        {"categorizations":[
          {"category_name":"Food"},
          {"transaction_id":"2"},
          {"transaction_id":"3","category_name":"Food"},
          {"transaction_id":"4","category_name":"Food"}
        ]}
      JSON

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal %w[2 3 4], result.map(&:transaction_id), "only the id-less item should be dropped"
    assert_nil result.first.category_name, "an omitted category field should be kept as nil, not dropped"
  end

  test "auto mode still falls back to none mode on HTTP 400" do
    call_params = []
    @client.expects(:chat).twice
      .with { |args| call_params << args[:parameters]; true }
      .raises(Faraday::BadRequestError.new("400"))
      .then
      .returns(chat_response('{"categorizations":[{"transaction_id":"1","category_name":"Food"}]}'))

    result = categorizer(json_mode: "auto").auto_categorize

    assert_equal "Food", result.first.category_name
    assert call_params.first[:response_format].present?
    assert_nil call_params.second[:response_format]
  end

  private

    def categorizer(json_mode:)
      Provider::Openai::AutoCategorizer.new(
        @client,
        model: "test-model",
        transactions: @transactions,
        user_categories: @user_categories,
        custom_provider: true,
        json_mode: json_mode
      )
    end

    def chat_response(content)
      {
        "choices" => [ { "message" => { "content" => content } } ],
        "usage" => { "total_tokens" => 1 }
      }
    end
end
