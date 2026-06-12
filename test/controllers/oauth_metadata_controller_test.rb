require "test_helper"

class OauthMetadataControllerTest < ActionDispatch::IntegrationTest
  setup do
    @base = ENV["APP_URL"].presence&.chomp("/") || "http://www.example.com"
  end

  test "protected_resource returns RFC 9728 metadata" do
    get "/.well-known/oauth-protected-resource"

    assert_response :ok
    assert_equal "application/json", response.content_type.split(";").first
    json = JSON.parse(response.body)
    assert_equal @base, json["resource"]
    assert_equal [ @base ], json["authorization_servers"]
  end

  test "authorization_server returns RFC 8414 metadata" do
    get "/.well-known/oauth-authorization-server"

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @base, json["issuer"]
    assert_equal "#{@base}/oauth/authorize", json["authorization_endpoint"]
    assert_equal "#{@base}/oauth/token", json["token_endpoint"]
    assert_equal "#{@base}/register", json["registration_endpoint"]
    assert_equal [ "code" ], json["response_types_supported"]
    assert_equal [ "authorization_code" ], json["grant_types_supported"]
    assert_equal [ "S256" ], json["code_challenge_methods_supported"]
    assert_equal [ "read_write" ], json["scopes_supported"]
  end
end
