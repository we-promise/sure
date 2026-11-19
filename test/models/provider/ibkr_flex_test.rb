require "test_helper"

class Provider::IbkrFlexTest < ActiveSupport::TestCase
  BASE_URL = "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService".freeze
  SUCCESS = "<FlexStatementResponse><Status>Success</Status><ReferenceCode>REF1</ReferenceCode></FlexStatementResponse>".freeze
  THROTTLED = "<FlexStatementResponse><Status>Fail</Status><ErrorCode>1018</ErrorCode>" \
    "<ErrorMessage>Too many requests have been made from this token. Please try again shortly.</ErrorMessage></FlexStatementResponse>".freeze
  STATEMENT = "<FlexQueryResponse><FlexStatements count=\"0\" /></FlexQueryResponse>".freeze

  setup do
    @provider = Provider::IbkrFlex.new(query_id: "QUERY123", token: "TOKEN123")
    @provider.stubs(:sleep)
    stub_request(:get, "#{BASE_URL}/GetStatement").with(query: hash_including("q" => "REF1")).to_return(body: STATEMENT)
  end

  test "uses the query's saved period when no dates are given" do
    send_request = stub_request(:get, "#{BASE_URL}/SendRequest")
      .with(query: { "t" => "TOKEN123", "q" => "QUERY123", "v" => "3" })
      .to_return(body: SUCCESS)

    assert_equal STATEMENT, @provider.download_statement
    assert_requested send_request, times: 1
  end

  test "requests a date range as fd and td in yyyymmdd" do
    send_request = stub_request(:get, "#{BASE_URL}/SendRequest")
      .with(query: { "t" => "TOKEN123", "q" => "QUERY123", "v" => "3", "fd" => "20240508", "td" => "20250507" })
      .to_return(body: SUCCESS)

    @provider.download_statement(from_date: Date.new(2024, 5, 8), to_date: Date.new(2025, 5, 7))

    assert_requested send_request, times: 1
  end

  test "waits and retries when IBKR says the token made too many requests" do
    send_request = stub_request(:get, "#{BASE_URL}/SendRequest")
      .with(query: hash_including("q" => "QUERY123"))
      .to_return({ body: THROTTLED }, { body: SUCCESS })
    @provider.expects(:sleep).with(Provider::IbkrFlex::THROTTLE_RETRY_DELAY).once

    assert_equal STATEMENT, @provider.download_statement
    assert_requested send_request, times: 2
  end

  test "a throttled GetStatement is retried too" do
    stub_request(:get, "#{BASE_URL}/SendRequest").with(query: hash_including("q" => "QUERY123")).to_return(body: SUCCESS)
    stub_request(:get, "#{BASE_URL}/GetStatement").with(query: hash_including("q" => "REF1"))
      .to_return({ body: THROTTLED }, { body: STATEMENT })

    assert_equal STATEMENT, @provider.download_statement
  end

  # 10 requests a minute per token, whatever IBKR answers.
  test "calls are spaced to IBKR's per-token limit" do
    sleeps = []
    @provider.stubs(:sleep).with { |seconds| sleeps << seconds }
    stub_request(:get, "#{BASE_URL}/SendRequest").with(query: hash_including("q" => "QUERY123")).to_return(body: SUCCESS)

    6.times { |i| @provider.download_statement(from_date: Date.new(2024 - i, 1, 1), to_date: Date.new(2024 - i, 12, 31)) }

    assert_requested :get, /FlexWebService/, times: 12
    assert_operator sleeps.sum, :>=, 60, "12 requests in #{sleeps.sum}s"
  end

  test "a network retry is spaced to IBKR's per-token limit too" do
    sleeps = []
    @provider.stubs(:sleep).with { |seconds| sleeps << seconds }
    stub_request(:get, "#{BASE_URL}/SendRequest").with(query: hash_including("q" => "QUERY123"))
      .to_raise(EOFError).then.to_return(body: SUCCESS)

    assert_equal STATEMENT, @provider.download_statement

    assert_requested :get, /FlexWebService/, times: 3
    assert_operator sleeps.sum, :>=, 2 * Provider::IbkrFlex::REQUEST_INTERVAL - 1, "3 requests in #{sleeps.sum}s"
  end

  test "gives up on throttling after a bounded number of retries" do
    stub_request(:get, "#{BASE_URL}/SendRequest")
      .with(query: hash_including("q" => "QUERY123"))
      .to_return(body: THROTTLED)

    error = assert_raises(Provider::IbkrFlex::ApiError) { @provider.download_statement }

    assert_equal "1018", error.error_code
    assert_requested :get, "#{BASE_URL}/SendRequest", query: hash_including("q" => "QUERY123"),
      times: Provider::IbkrFlex::MAX_THROTTLE_RETRIES + 1
  end

  # A maintenance page or a cut-off transfer carries no IBKR code, so history import retries it
  test "an HTML page or a cut-off GetStatement raises an ApiError without an error code" do
    stub_request(:get, "#{BASE_URL}/SendRequest").with(query: hash_including("q" => "QUERY123")).to_return(body: SUCCESS)
    stub_request(:get, "#{BASE_URL}/GetStatement").with(query: hash_including("q" => "REF1"))
      .to_return({ body: "<!DOCTYPE html><html><body>Maintenance</body></html>" }).then.to_raise(EOFError)

    2.times { assert_nil assert_raises(Provider::IbkrFlex::ApiError) { @provider.download_statement }.error_code }
  end
end
