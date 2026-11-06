# frozen_string_literal: true

require "test_helper"

class Api::V1::VersionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.configuration.stubs(:public_version_endpoint).returns(false)
    Sure.stubs(:version).returns(Calver.new("2026.11.2"))
    Sure.stubs(:commit_sha).returns("a" * 40)
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(user: @user, name: "Version reader", scopes: [ "read" ],
      source: "web", display_key: "version_#{SecureRandom.hex(16)}")
  end

  test "requires authentication by default without disclosing metadata" do
    get api_v1_version_url
    assert_response :unauthorized
    assert_not response.parsed_body.key?("version")
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "read key returns only version and commit with no caching" do
    get api_v1_version_url, headers: api_headers(@api_key)
    assert_response :success
    assert_equal({ "version" => "2026.11.2", "commit_sha" => "a" * 40 }, response.parsed_body)
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "application/json", response.media_type
  end

  test "read write key can query version" do
    @api_key.update!(scopes: [ "read_write" ])
    get api_v1_version_url, headers: api_headers(@api_key)
    assert_response :success
  end

  test "key without read scope is forbidden" do
    @api_key.update_columns(scopes: [])
    get api_v1_version_url, headers: api_headers(@api_key)
    assert_response :forbidden
  end

  test "invalid and revoked keys cannot query version" do
    get api_v1_version_url, headers: { "X-Api-Key" => "invalid" }
    assert_response :unauthorized
    @api_key.update!(revoked_at: Time.current)
    get api_v1_version_url, headers: api_headers(@api_key)
    assert_response :unauthorized
  end

  test "public opt in allows anonymous access but does not open other APIs" do
    Rails.configuration.stubs(:public_version_endpoint).returns(true)
    get api_v1_version_url
    assert_response :success
    assert_equal [ "commit_sha", "version" ], response.parsed_body.keys.sort
    assert_includes response.headers["Cache-Control"], "no-store"
    get api_v1_accounts_url
    assert_response :unauthorized
  end

  test "public opt in still validates supplied credentials" do
    Rails.configuration.stubs(:public_version_endpoint).returns(true)
    get api_v1_version_url, headers: { "X-Api-Key" => "invalid" }
    assert_response :unauthorized
  end

  test "missing build commit is null" do
    Sure.stubs(:commit_sha).returns("")
    get api_v1_version_url, headers: api_headers(@api_key)
    assert_response :success
    assert_nil response.parsed_body.fetch("commit_sha")
  end

  test "public opt in rejects empty and whitespace API keys" do
    Rails.configuration.stubs(:public_version_endpoint).returns(true)

    [ "", "   " ].each do |key|
      get api_v1_version_url, headers: { "X-Api-Key" => key }
      assert_response :unauthorized
      assert_not response.parsed_body.key?("version")
      assert_includes response.headers["Cache-Control"], "no-store"
    end
  end

  test "public opt in still enforces read scope on supplied keys" do
    Rails.configuration.stubs(:public_version_endpoint).returns(true)
    @api_key.update_columns(scopes: [])

    get api_v1_version_url, headers: api_headers(@api_key)
    assert_response :forbidden
  end

  private
    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
