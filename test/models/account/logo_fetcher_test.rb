# frozen_string_literal: true

require "test_helper"

class Account::LogoFetcherTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @account.update!(institution_domain: "example.com", logo_source: "auto")
    @account.logo.purge if @account.logo.attached?
  end

  test "fetches and attaches logo from Brandfetch when configured" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    fake_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    fake_response.stubs(:body).returns("fake-brandfetch-image-data")
    fake_response.stubs(:content_type).returns("image/png")

    http_mock = mock
    http_mock.expects(:use_ssl=).with(true)
    http_mock.expects(:open_timeout=).with(5)
    http_mock.expects(:read_timeout=).with(5)
    http_mock.expects(:request).returns(fake_response)

    Net::HTTP.stubs(:new).with("cdn.brandfetch.io", 443).returns(http_mock)

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/png", @account.logo.blob.content_type
    assert @account.logo_source_auto?, "a fetched logo must keep logo_source auto"
  end

  test "falls back to DuckDuckGo when Brandfetch returns non-200" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    brandfetch_fail = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    brandfetch_fail.stubs(:body).returns(nil)

    ddg_success = Net::HTTPSuccess.new("1.1", "200", "OK")
    ddg_success.stubs(:body).returns("fake-favicon-data")
    ddg_success.stubs(:content_type).returns("image/x-icon")

    bf_http = mock
    bf_http.stubs(:use_ssl=)
    bf_http.stubs(:open_timeout=)
    bf_http.stubs(:read_timeout=)
    bf_http.expects(:request).returns(brandfetch_fail)

    ddg_http = mock
    ddg_http.stubs(:use_ssl=)
    ddg_http.stubs(:open_timeout=)
    ddg_http.stubs(:read_timeout=)
    ddg_http.expects(:request).returns(ddg_success)

    Net::HTTP.stubs(:new).with("cdn.brandfetch.io", 443).returns(bf_http)
    Net::HTTP.stubs(:new).with("icons.duckduckgo.com", 443).returns(ddg_http)

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/x-icon", @account.logo.blob.content_type
  end

  test "fetches the provider logo before the favicon fallback" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    provider = OpenStruct.new(logo_url: "https://provider.example.com/logo.png")
    @account.stubs(:provider).returns(provider)

    provider_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    provider_response.stubs(:body).returns("provider-logo-data")
    provider_response.stubs(:content_type).returns("image/png")

    provider_http = mock
    provider_http.stubs(:use_ssl=)
    provider_http.stubs(:open_timeout=)
    provider_http.stubs(:read_timeout=)
    provider_http.expects(:request).returns(provider_response)

    Net::HTTP.stubs(:new).with("provider.example.com", 443).returns(provider_http)
    Net::HTTP.expects(:new).with("icons.duckduckgo.com", 443).never

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/png", @account.logo.blob.content_type
  end

  test "rejects a non-image response and falls back to DuckDuckGo" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    html_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    html_response.stubs(:body).returns("<html>rate limited</html>")
    html_response.stubs(:content_type).returns("text/html")

    ddg_success = Net::HTTPSuccess.new("1.1", "200", "OK")
    ddg_success.stubs(:body).returns("fake-favicon-data")
    ddg_success.stubs(:content_type).returns("image/x-icon")

    bf_http = mock
    bf_http.stubs(:use_ssl=)
    bf_http.stubs(:open_timeout=)
    bf_http.stubs(:read_timeout=)
    bf_http.expects(:request).returns(html_response)

    ddg_http = mock
    ddg_http.stubs(:use_ssl=)
    ddg_http.stubs(:open_timeout=)
    ddg_http.stubs(:read_timeout=)
    ddg_http.expects(:request).returns(ddg_success)

    Net::HTTP.stubs(:new).with("cdn.brandfetch.io", 443).returns(bf_http)
    Net::HTTP.stubs(:new).with("icons.duckduckgo.com", 443).returns(ddg_http)

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/x-icon", @account.logo.blob.content_type
  end

  test "does not attach a stale logo when the domain changed since enqueue" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    ddg_success = Net::HTTPSuccess.new("1.1", "200", "OK")
    ddg_success.stubs(:body).returns("stale-favicon-data")
    ddg_success.stubs(:content_type).returns("image/x-icon")

    ddg_http = mock
    ddg_http.stubs(:use_ssl=)
    ddg_http.stubs(:open_timeout=)
    ddg_http.stubs(:read_timeout=)
    ddg_http.expects(:request).returns(ddg_success)

    Net::HTTP.stubs(:new).with("icons.duckduckgo.com", 443).returns(ddg_http)

    # The job was enqueued while the domain was still old.example.com
    fetcher = Account::LogoFetcher.new(@account, expected_domain: "old.example.com")
    @account.update!(institution_domain: "new.example.com")

    fetcher.fetch_and_attach

    assert_not @account.logo.attached?
  end

  test "rejects image types outside the allowlist and falls back" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    odd_image = Net::HTTPSuccess.new("1.1", "200", "OK")
    odd_image.stubs(:body).returns("odd-image-data")
    odd_image.stubs(:content_type).returns("image/heif-sequence")

    ddg_success = Net::HTTPSuccess.new("1.1", "200", "OK")
    ddg_success.stubs(:body).returns("fake-favicon-data")
    ddg_success.stubs(:content_type).returns("image/x-icon")

    bf_http = mock
    bf_http.stubs(:use_ssl=)
    bf_http.stubs(:open_timeout=)
    bf_http.stubs(:read_timeout=)
    bf_http.expects(:request).returns(odd_image)

    ddg_http = mock
    ddg_http.stubs(:use_ssl=)
    ddg_http.stubs(:open_timeout=)
    ddg_http.stubs(:read_timeout=)
    ddg_http.expects(:request).returns(ddg_success)

    Net::HTTP.stubs(:new).with("cdn.brandfetch.io", 443).returns(bf_http)
    Net::HTTP.stubs(:new).with("icons.duckduckgo.com", 443).returns(ddg_http)

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/x-icon", @account.logo.blob.content_type
  end

  test "does not overwrite manual logo when logo_source is manual" do
    @account.update!(logo_source: "manual")
    @account.logo.attach(
      io: StringIO.new("custom-manual-logo"),
      filename: "custom.png",
      content_type: "image/png"
    )

    Net::HTTP.expects(:new).never

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert_equal "custom.png", @account.logo.blob.filename.to_s
  end
end
