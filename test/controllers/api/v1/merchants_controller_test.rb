# frozen_string_literal: true

require "test_helper"

class Api::V1::MerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_family_user = users(:empty)

    assert_not_equal @user.family_id, @other_family_user.family_id,
      "Test setup error: @other_family_user must belong to a different family"

    @user.api_keys.active.destroy_all

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test App",
      redirect_uri: "https://example.com/callback",
      scopes: "read"
    )

    @access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    @merchant = @user.family.merchants.first || @user.family.merchants.create!(
      name: "Test Merchant"
    )
  end

  # Index action tests
  test "index requires authentication" do
    get api_v1_merchants_url

    assert_response :unauthorized
  end

  test "index returns user's family merchants successfully" do
    get api_v1_merchants_url, headers: auth_headers

    assert_response :success

    merchants = JSON.parse(response.body)
    assert_kind_of Array, merchants
    assert_not_empty merchants

    merchant = merchants.first
    assert merchant.key?("id")
    assert merchant.key?("name")
    assert merchant.key?("created_at")
    assert merchant.key?("updated_at")
  end

  test "index does not return merchants from other families" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    get api_v1_merchants_url, headers: auth_headers

    assert_response :success
    merchants = JSON.parse(response.body)
    merchant_ids = merchants.map { |m| m["id"] }

    assert_includes merchant_ids, @merchant.id
    assert_not_includes merchant_ids, other_merchant.id
  end

  # Show action tests
  test "show requires authentication" do
    get api_v1_merchant_url(@merchant)

    assert_response :unauthorized
  end

  test "show returns merchant successfully" do
    get api_v1_merchant_url(@merchant), headers: auth_headers

    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal @merchant.id, merchant["id"]
    assert_equal @merchant.name, merchant["name"]
  end

  test "show returns 404 for non-existent merchant" do
    get api_v1_merchant_url(id: SecureRandom.uuid), headers: auth_headers

    assert_response :not_found
  end

  test "show returns 404 for merchant from another family" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    get api_v1_merchant_url(other_merchant), headers: auth_headers

    assert_response :not_found
  end

  # Create (CSV import) action tests
  test "create requires authentication" do
    post api_v1_merchants_url, params: { file: csv_file("name\nNew Merchant") }

    assert_response :unauthorized
  end

  test "create rejects read-only api key" do
    post api_v1_merchants_url,
      params: { file: csv_file("name\nNew Merchant") },
      headers: api_headers(read_only_api_key)

    assert_response :forbidden
  end

  test "create imports merchants from csv" do
    csv_content = "name,color,website_url\nImported Merchant,#ff0000,https://example.com\nAnother Merchant,,"

    assert_difference "@user.family.merchants.count", 2 do
      post api_v1_merchants_url,
        params: { file: csv_file(csv_content) },
        headers: api_headers(read_write_api_key)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 2, body["imported"]
    assert_equal 0, body["skipped"]
    assert_equal 2, body["merchants"].length

    imported = body["merchants"].find { |m| m["name"] == "Imported Merchant" }
    assert imported.present?
    assert imported["id"].present?
    assert_equal "FamilyMerchant", imported["type"]
  end

  test "create skips duplicate merchant names" do
    csv_content = "name\n#{@merchant.name}\nBrand New Merchant"

    assert_difference "@user.family.merchants.count", 1 do
      post api_v1_merchants_url,
        params: { file: csv_file(csv_content) },
        headers: api_headers(read_write_api_key)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 1, body["imported"]
    assert_equal 1, body["skipped"]
  end

  test "create returns 422 when file is missing" do
    post api_v1_merchants_url, headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "missing_file", body["error"]
  end

  test "create returns 422 when csv is missing name column" do
    csv_content = "color,website_url\n#ff0000,https://example.com"

    post api_v1_merchants_url,
      params: { file: csv_file(csv_content) },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "missing_column", body["error"]
  end

  test "create returns 422 for invalid file type" do
    file = Rack::Test::UploadedFile.new(
      StringIO.new("not a csv"),
      "application/pdf",
      true,
      original_filename: "merchants.pdf"
    )

    post api_v1_merchants_url,
      params: { file: file },
      headers: api_headers(read_write_api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "invalid_file_type", body["error"]
  end

  private

    def auth_headers
      { "Authorization" => "Bearer #{@access_token.token}" }
    end

    def read_write_api_key
      @read_write_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test RW Key",
        key: ApiKey.generate_secure_key,
        scopes: %w[read_write],
        source: "web"
      )
    end

    def read_only_api_key
      @read_only_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test RO Key",
        key: ApiKey.generate_secure_key,
        scopes: %w[read],
        source: "mobile"
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def csv_file(content, filename: "merchants.csv")
      uploaded_file(filename: filename, content_type: "text/csv", content: content)
    end
end
