require "test_helper"

class Provider::IbkrFlexNativeTest < ActiveSupport::TestCase
  setup do
    @client = Provider::IbkrFlex.new(query_id: "query", token: "secret")
  end

  test "request makes one nonredirecting GET and returns captured reference evidence" do
    xml = '<FlexStatementResponse><Status>Success</Status><ReferenceCode>ref_123</ReferenceCode></FlexStatementResponse>'
    Provider::IbkrFlex.expects(:get).once.with("/SendRequest", query: { t: "secret", q: "query", v: 3 }, follow_redirects: false).returns(response(xml))
    result = @client.request_statement_page
    assert_equal "requested", result[:status]
    assert_equal "ref_123", result[:reference]
    assert_equal xml, result[:evidence]["response_xml"]
  end

  test "pending code returns after one physical poll without retrying" do
    xml = '<FlexStatementResponse><Status>Fail</Status><ErrorCode>1019</ErrorCode></FlexStatementResponse>'
    Provider::IbkrFlex.expects(:get).once.with("/GetStatement", query: { t: "secret", q: "ref_123", v: 3 }, follow_redirects: false).returns(response(xml))
    result = @client.poll_statement_page(reference: "ref_123")
    assert_equal "pending", result[:status]
    assert_equal xml, result[:evidence]["response_xml"]
  end

  test "ready XML is returned unchanged for durable archiving" do
    xml = file_fixture("ibkr/flex_statement.xml").read
    Provider::IbkrFlex.expects(:get).once.returns(response(xml))
    result = @client.poll_statement_page(reference: "ref_123")
    assert_equal "ready", result[:status]
    assert_equal xml, result[:xml]
  end

  test "transport failure is sanitized and never silently retries" do
    Provider::IbkrFlex.expects(:get).once.raises(Net::ReadTimeout, "secret private response")
    error = assert_raises(Provider::IbkrFlex::ApiError) { @client.request_statement_page }
    assert_nil error.cause
    assert_not_includes error.message, "secret"
    assert_nil error.response_body
  end

  test "authentication and configuration errors do not expose upstream text" do
    [ [ "1012", Provider::IbkrFlex::AuthenticationError ], [ "1014", Provider::IbkrFlex::ConfigurationError ] ].each do |code, klass|
      xml = "<FlexStatementResponse><Status>Fail</Status><ErrorCode>#{code}</ErrorCode><ErrorMessage>secret</ErrorMessage></FlexStatementResponse>"
      Provider::IbkrFlex.expects(:get).once.returns(response(xml))
      error = assert_raises(klass) { @client.request_statement_page }
      assert_not_includes error.message, "secret"
    end
  end

  test "HTTP failures and redirects never turn a Flex body into ready data" do
    Provider::IbkrFlex.expects(:get).once.returns(response("secret", code: 401))
    assert_raises(Provider::IbkrFlex::AuthenticationError) { @client.request_statement_page }
    Provider::IbkrFlex.expects(:get).once.returns(response(file_fixture("ibkr/flex_statement.xml").read, code: 302))
    error = assert_raises(Provider::IbkrFlex::ApiError) { @client.poll_statement_page(reference: "ref_123") }
    assert_nil error.response_body
  end

  test "references are validated before request and XML must be strict without entities" do
    assert_raises(Provider::IbkrFlex::ApiError) { @client.poll_statement_page(reference: "https://other/secret") }
    [ "<FlexQueryResponse>", "<Unrelated />", '<!DOCTYPE x [<!ENTITY secret SYSTEM "file:///secret">]><FlexQueryResponse />' ].each do |body|
      Provider::IbkrFlex.expects(:get).once.returns(response(body))
      error = assert_raises(Provider::IbkrFlex::ApiError) { @client.request_statement_page }
      assert_nil error.response_body
    end
  end

  private
    def response(body, code: 200)
      stub(body: body, code: code, success?: code == 200)
    end
end
