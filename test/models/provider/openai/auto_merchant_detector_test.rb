require "test_helper"

class Provider::Openai::AutoMerchantDetectorTest < ActiveSupport::TestCase
  setup do
    @client = mock
    @transactions = [
      { id: "1", name: "AMAZON.COM*1A2B3C", amount: 20, classification: "expense" }
    ]
    @user_merchants = [ { name: "Amazon" } ]
  end

  test "auto mode retries without response_format when strict JSON cannot be parsed" do
    call_params = []
    @client.expects(:chat).twice
      .with { |args| call_params << args[:parameters]; true }
      .returns(
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Ama'),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal 1, result.size
    assert_equal "Amazon", result.first.business_name
    assert_equal "amazon.com", result.first.business_url
    assert call_params.first[:response_format].present?, "strict attempt should send response_format"
    assert_nil call_params.second[:response_format], "retry should omit response_format"
  end

  test "auto mode retries when strict response parses but has the wrong shape" do
    @client.expects(:chat).twice
      .returns(
        chat_response('{"foo": []}'),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
  end

  test "auto mode accepts a top-level JSON array in a single call" do
    @client.expects(:chat).once
      .returns(chat_response('[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]'))

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
  end

  test "auto mode retries when strict response is a JSON scalar" do
    @client.expects(:chat).twice
      .returns(
        chat_response("null"),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
  end

  test "auto mode retries when every strict response item is malformed" do
    @client.expects(:chat).twice
      .returns(
        chat_response('{"merchants":[{}]}'),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
  end

  test "auto mode drops malformed items below the retry threshold instead of returning nil fields" do
    @transactions.concat([
      { id: "2", name: "SHELL OIL", amount: 50, classification: "expense" },
      { id: "3", name: "NETFLIX", amount: 15, classification: "expense" },
      { id: "4", name: "SPOTIFY", amount: 10, classification: "expense" }
    ])

    @client.expects(:chat).once
      .returns(chat_response(<<~JSON.squish))
        {"merchants":[
          {"transaction_id":"1","business_name":"Amazon"},
          {"transaction_id":"2","business_name":null,"business_url":null},
          {"transaction_id":"3","business_name":"Netflix","business_url":"netflix.com"},
          {"transaction_id":"4","business_name":"Spotify","business_url":"spotify.com"}
        ]}
      JSON

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal 3, result.size
    assert result.all? { |r| r.transaction_id.present? }
  end

  test "auto mode does not fire a second fallback when the none-mode retry returns HTTP 400" do
    @client.expects(:chat).twice
      .returns(chat_response('{"merchants":[{"transaction_id":"1"'))
      .then
      .raises(Faraday::BadRequestError.new("400"))

    assert_raises Faraday::BadRequestError do
      detector(json_mode: "auto").auto_detect_merchants
    end
  end

  test "auto mode makes a single call when strict returns merchants for all transactions" do
    @client.expects(:chat).once
      .returns(chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}'))

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal 1, result.size
    assert_equal "Amazon", result.first.business_name
  end

  test "strict mode raises ResponseFormatError on unparseable JSON without retrying" do
    @client.expects(:chat).once
      .returns(chat_response('{"merchants":[{"transaction_id":"1"'))

    assert_raises Provider::Openai::ResponseFormatError do
      detector(json_mode: "strict").auto_detect_merchants
    end
  end

  private

    def detector(json_mode:)
      Provider::Openai::AutoMerchantDetector.new(
        @client,
        model: "test-model",
        transactions: @transactions,
        user_merchants: @user_merchants,
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
