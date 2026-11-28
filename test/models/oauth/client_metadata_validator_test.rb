require "test_helper"

class Oauth::ClientMetadataValidatorTest < ActiveSupport::TestCase
  test "error_for returns nil for valid metadata and enforces check precedence" do
    assert_nil Oauth::ClientMetadataValidator.error_for(
      redirect_uris: [ "https://claude.ai/callback" ],
      client_name: "Claude"
    )
    assert_nil Oauth::ClientMetadataValidator.error_for(
      redirect_uris: [ "https://claude.ai/callback" ]
    )

    assert_equal :redirect_uris_required, Oauth::ClientMetadataValidator.error_for(
      redirect_uris: [],
      client_name: "\u202ESure"
    )
    assert_equal :invalid_redirect_uris, Oauth::ClientMetadataValidator.error_for(
      redirect_uris: [ "javascript:alert(1)" ],
      client_name: "\u202ESure"
    )
    assert_equal :invalid_client_name, Oauth::ClientMetadataValidator.error_for(
      redirect_uris: [ "https://claude.ai/callback" ],
      client_name: "\u202ESure"
    )
    assert_equal :reserved_client_name, Oauth::ClientMetadataValidator.error_for(
      redirect_uris: [ "https://claude.ai/callback" ],
      client_name: "Sure Mobile"
    )
  end

  test "normalize_redirect_uris strips whitespace and drops blank entries" do
    assert_equal [ "https://claude.ai/callback" ],
      Oauth::ClientMetadataValidator.normalize_redirect_uris([ "  https://claude.ai/callback  ", "", "   ", nil ])
    assert_equal [], Oauth::ClientMetadataValidator.normalize_redirect_uris(nil)
    assert_equal [], Oauth::ClientMetadataValidator.normalize_redirect_uris(false)
    assert_equal [], Oauth::ClientMetadataValidator.normalize_redirect_uris("")
    assert_equal [], Oauth::ClientMetadataValidator.normalize_redirect_uris([ "" ])
  end

  test "valid_redirect_uri? accepts https, loopback http, and private-use native schemes" do
    [
      "https://claude.ai/callback",
      "http://localhost:3456/callback",
      "http://127.0.0.1:8787/callback",
      "http://[::1]:3456/callback",
      "cursor://anysphere.cursor-mcp/oauth/callback",
      "vscode://augment.vscode-augment/auth/mcp",
      "com.example.app:/oauth2redirect/example-provider"
    ].each do |uri|
      assert Oauth::ClientMetadataValidator.valid_redirect_uri?(uri), "expected #{uri} to be valid"
    end
  end

  test "valid_redirect_uri? rejects non-loopback http, forbidden schemes, fragments, userinfo, and malformed URIs" do
    [
      "http://evil.example/callback",
      "https://",
      "http://",
      "javascript:alert(1)",
      "file:///etc/passwd",
      "data:text/html,hello",
      "tel:+15551212",
      "sms:+15551212",
      "intent://scan/oauth",
      "https://claude.ai/callback#fragment",
      "https://claude.ai/callback#",
      "https://user:pass@claude.ai/callback",
      "cursor://",
      "not a valid uri"
    ].each do |uri|
      assert_not Oauth::ClientMetadataValidator.valid_redirect_uri?(uri), "expected #{uri} to be rejected"
    end
  end

  test "bidi_control? detects bidirectional control characters" do
    [ "\u202Eelibom erus", "Claude\u2066 Agent\u2069", "Agent\u200F" ].each do |name|
      assert Oauth::ClientMetadataValidator.bidi_control?(name), "expected #{name.inspect} to match bidi_control?"
    end

    assert_not Oauth::ClientMetadataValidator.bidi_control?("Claude Desktop")
    assert_not Oauth::ClientMetadataValidator.bidi_control?(nil)
  end

  test "reserved_client_name? rejects Sure and confusable look-alikes" do
    [
      "Sure Mobile", "sure mobile", "SURE-Mobile", "Sure", "Official Sure App", "SureMobile", "SureMobileApp",
      "Su\u200Bre Mobile", "Su\u034Fre Mobile", "Su\uFE0Fre Mobile", "Su\u3164re Mobile", "S\u0332ure Mobile",
      "\uFF33\uFF55\uFF52\uFF45 Mobile", "\u0405ur\u0435 Mobile", "S\u057Dre", "\u0405URE \u041C\u041EBILE",
      "Su\u0433e Mobile", "S\u0443re Mobile", "S u r e Mobile", "S.u.r.e", "S-u-r-e Mobile", "SureMo bile App"
    ].each do |name|
      assert Oauth::ClientMetadataValidator.reserved_client_name?(name), "expected #{name.inspect} to be reserved"
    end
  end

  test "reserved_client_name? allows names containing sure inside another word" do
    [ "Measure MCP", "Measure Mobile", "Surefire Agent", "Su Pre Agent", "Sur Ely", "S\u00FCre Notes", "\u041C\u043E\u0439 \u043A\u043B\u0438\u0435\u043D\u0442" ].each do |name|
      assert_not Oauth::ClientMetadataValidator.reserved_client_name?(name), "expected #{name.inspect} to be allowed"
    end
  end
end
