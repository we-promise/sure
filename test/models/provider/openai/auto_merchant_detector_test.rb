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
