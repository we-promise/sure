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

    # Mock DNS resolution to return a known IP
    Resolv.stubs(:getaddresses).with("cdn.brandfetch.io").returns([ "18.160.41.3" ])

    fake_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    fake_response.stubs(:content_type).returns("image/png")
    fake_response.stubs(:content_length).returns(nil)
    fake_response.stubs(:read_body).yields("fake-brandfetch-image-data")

    http_mock = mock
    http_mock.expects(:use_ssl=).with(true)
    http_mock.expects(:open_timeout=).with(5)
    http_mock.expects(:read_timeout=).with(5)
    http_mock.expects(:request).yields(fake_response)

    Net::HTTP.stubs(:new).with("cdn.brandfetch.io", 443).returns(http_mock)

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/png", @account.logo.blob.content_type
    assert @account.logo_source_auto?, "a fetched logo must keep logo_source auto"
  end

  test "falls back to DuckDuckGo when Brandfetch returns non-200" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    # Mock DNS resolution
    Resolv.stubs(:getaddresses).with("cdn.brandfetch.io").returns([ "18.160.41.3" ])
    Resolv.stubs(:getaddresses).with("icons.duckduckgo.com").returns([ "18.160.41.80" ])

    brandfetch_fail = Net::HTTPNotFound.new("1.1", "404", "Not Found")

    ddg_success = Net::HTTPSuccess.new("1.1", "200", "OK")
    ddg_success.stubs(:content_type).returns("image/x-icon")
    ddg_success.stubs(:content_length).returns(nil)
    ddg_success.stubs(:read_body).yields("fake-favicon-data")

    bf_http = mock
    bf_http.stubs(:use_ssl=)
    bf_http.stubs(:open_timeout=)
    bf_http.stubs(:read_timeout=)
    bf_http.expects(:request).yields(brandfetch_fail)

    ddg_http = mock
    ddg_http.stubs(:use_ssl=)
    ddg_http.stubs(:open_timeout=)
    ddg_http.stubs(:read_timeout=)
    ddg_http.expects(:request).yields(ddg_success)

    Net::HTTP.stubs(:new).with("cdn.brandfetch.io", 443).returns(bf_http)
    Net::HTTP.stubs(:new).with("icons.duckduckgo.com", 443).returns(ddg_http)

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/x-icon", @account.logo.blob.content_type
  end

  test "fetches the provider logo before the favicon fallback" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    provider = OpenStruct.new(
      logo_url: "https://provider.example.com/logo.png"
    )
    @account.stubs(:provider).returns(provider)

    Resolv.stubs(:getaddresses).with("provider.example.com").returns([ "8.8.8.8" ])

    provider_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    provider_response.stubs(:content_type).returns("image/png")
    provider_response.stubs(:content_length).returns(nil)
    provider_response.stubs(:read_body).yields("provider-logo-data")

    provider_http = mock
    provider_http.stubs(:use_ssl=)
    provider_http.stubs(:open_timeout=)
    provider_http.stubs(:read_timeout=)
    provider_http.expects(:request).yields(provider_response)

    Net::HTTP.stubs(:new).with("provider.example.com", 443).returns(provider_http)
    Net::HTTP.expects(:new).with("icons.duckduckgo.com", 443).never

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/png", @account.logo.blob.content_type
  end

  test "rejects a non-image response and falls back to DuckDuckGo" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    # Mock DNS resolution
    Resolv.stubs(:getaddresses).with("cdn.brandfetch.io").returns([ "18.160.41.3" ])
    Resolv.stubs(:getaddresses).with("icons.duckduckgo.com").returns([ "18.160.41.80" ])

    html_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    html_response.stubs(:content_type).returns("text/html")
    html_response.stubs(:content_length).returns(nil)
    html_response.stubs(:read_body).yields("<html>rate limited</html>")

    ddg_success = Net::HTTPSuccess.new("1.1", "200", "OK")
    ddg_success.stubs(:content_type).returns("image/x-icon")
    ddg_success.stubs(:content_length).returns(nil)
    ddg_success.stubs(:read_body).yields("fake-favicon-data")

    bf_http = mock
    bf_http.stubs(:use_ssl=)
    bf_http.stubs(:open_timeout=)
    bf_http.stubs(:read_timeout=)
    bf_http.expects(:request).yields(html_response)

    ddg_http = mock
    ddg_http.stubs(:use_ssl=)
    ddg_http.stubs(:open_timeout=)
    ddg_http.stubs(:read_timeout=)
    ddg_http.expects(:request).yields(ddg_success)

    Net::HTTP.stubs(:new).with("cdn.brandfetch.io", 443).returns(bf_http)
    Net::HTTP.stubs(:new).with("icons.duckduckgo.com", 443).returns(ddg_http)

    Account::LogoFetcher.new(@account).fetch_and_attach

    assert @account.logo.attached?
    assert_equal "image/x-icon", @account.logo.blob.content_type
  end

  test "does not attach a stale logo when the domain changed since enqueue" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    fetcher = Account::LogoFetcher.new(
      @account,
      expected_domain: "old.example.com"
    )

    @account.update!(institution_domain: "new.example.com")

    Net::HTTP.expects(:new).never

    fetcher.fetch_and_attach

    assert_not @account.logo.attached?
  end

  test "rejects image types outside the allowlist and falls back" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    # Mock DNS resolution
    Resolv.stubs(:getaddresses).with("cdn.brandfetch.io").returns([ "18.160.41.3" ])
    Resolv.stubs(:getaddresses).with("icons.duckduckgo.com").returns([ "18.160.41.80" ])

    odd_image = Net::HTTPSuccess.new("1.1", "200", "OK")
    odd_image.stubs(:content_type).returns("image/heif-sequence")
    odd_image.stubs(:content_length).returns(nil)
    odd_image.stubs(:read_body).yields("odd-image-data")

    ddg_success = Net::HTTPSuccess.new("1.1", "200", "OK")
    ddg_success.stubs(:content_type).returns("image/x-icon")
    ddg_success.stubs(:content_length).returns(nil)
    ddg_success.stubs(:read_body).yields("fake-favicon-data")

    bf_http = mock
    bf_http.stubs(:use_ssl=)
    bf_http.stubs(:open_timeout=)
    bf_http.stubs(:read_timeout=)
    bf_http.expects(:request).yields(odd_image)

    ddg_http = mock
    ddg_http.stubs(:use_ssl=)
    ddg_http.stubs(:open_timeout=)
    ddg_http.stubs(:read_timeout=)
    ddg_http.expects(:request).yields(ddg_success)

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
