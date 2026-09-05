require "test_helper"

class BaseUrlAllowlistableTest < ActiveSupport::TestCase
  class Subject
    extend BaseUrlAllowlistable

    DEFAULT_BASE_URL = "https://api.example.com/v1"
    ALLOWED_BASE_URLS = [ DEFAULT_BASE_URL, "https://api-sandbox.example.com/v1" ].freeze
  end

  # A provider that declared a cleartext URL by mistake must not thereby permit
  # cleartext. The entry is dropped rather than honoured, so nothing matches.
  class MisconfiguredSubject
    extend BaseUrlAllowlistable

    DEFAULT_BASE_URL = "http://api.example.com/v1"
    ALLOWED_BASE_URLS = [ DEFAULT_BASE_URL ].freeze
  end

  test "an http entry in the allow-list is ignored rather than honoured" do
    assert_nil MisconfiguredSubject.normalize_base_url("http://api.example.com/v1")
    assert_nil MisconfiguredSubject.normalize_base_url("https://api.example.com/v1")
  end

  test "a blank value resolves to the default" do
    [ nil, "", "   " ].each do |value|
      assert_equal Subject::DEFAULT_BASE_URL, Subject.normalize_base_url(value)
    end
  end

  test "accepts every URL on the list" do
    Subject::ALLOWED_BASE_URLS.each do |url|
      assert_equal url, Subject.normalize_base_url(url)
    end
  end

  test "accepts a listed URL written with a trailing slash or odd case" do
    assert_equal Subject::DEFAULT_BASE_URL, Subject.normalize_base_url("HTTPS://API.Example.com/v1/")
  end

  # The point of the allow-list: an operator cannot redirect the app's outbound
  # requests, credentials included, anywhere else.
  test "refuses anything that is not on the list" do
    [
      "https://evil.example.com/v1",
      "https://api.example.com.evil.test/v1",
      "https://api.example.com/v2",
      "http://api.example.com/v1",
      "https://169.254.169.254/v1",
      "https://localhost/v1",
      "not a url",
      "//api.example.com/v1"
    ].each do |value|
      assert_nil Subject.normalize_base_url(value), "#{value.inspect} must be refused"
      assert_not Subject.allowed_base_url?(value), "#{value.inspect} must be refused"
    end
  end

  # Each of these carries something the allow-list does not mention, so
  # comparing on host and path alone would let it through.
  test "refuses credentials, a query, a fragment or a non-default port" do
    [
      "https://user:pass@api.example.com/v1",
      "https://api.example.com/v1?x=1",
      "https://api.example.com/v1#x",
      "https://api.example.com:8443/v1"
    ].each do |value|
      assert_nil Subject.normalize_base_url(value), "#{value.inspect} must be refused"
    end
  end
end
