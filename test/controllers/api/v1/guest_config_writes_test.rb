# frozen_string_literal: true

require "test_helper"

class Api::V1::GuestConfigWritesTest < ActionDispatch::IntegrationTest
  setup do
    @guest = family_guest
    @headers = { "X-Api-Key" => guest_api_key.plain_key }
  end

  test "guest api keys can still read tags" do
    get api_v1_tags_url, headers: @headers

    assert_response :success
  end

  test "guest api keys cannot create, update or delete tags" do
    tag = @guest.family.tags.create!(name: "Guest-proof #{SecureRandom.hex(4)}", color: "#3b82f6")

    assert_no_difference("Tag.count") do
      post api_v1_tags_url, params: { tag: { name: "Guest tag" } }, headers: @headers
      assert_response :forbidden

      patch api_v1_tag_url(tag), params: { tag: { name: "Renamed" } }, headers: @headers
      assert_response :forbidden

      delete api_v1_tag_url(tag), headers: @headers
      assert_response :forbidden
    end

    assert_not_equal "Renamed", tag.reload.name
  end

  test "guest api keys cannot create categories" do
    assert_no_difference("Category.count") do
      post api_v1_categories_url, params: { category: { name: "Guest category" } }, headers: @headers
    end

    assert_response :forbidden
  end

  test "guest api keys cannot import merchants" do
    file = Rack::Test::UploadedFile.new(StringIO.new("name\nGuest Shop"), "text/csv", true, original_filename: "merchants.csv")

    assert_no_difference("FamilyMerchant.count") do
      post api_v1_merchants_url, params: { file: file }, headers: @headers
    end

    assert_response :forbidden
  end

  test "guest api keys cannot create family configuration imports or import sessions" do
    assert_no_difference([ "Import.count", "ImportSession.count" ]) do
      %w[CategoryImport MerchantImport RuleImport SureImport].each do |type|
        post api_v1_imports_url, params: { type: type, raw_file_content: "name\nGuest" }, headers: @headers
        assert_response :forbidden, "#{type} should be rejected for guests"
      end

      post api_v1_import_sessions_url, params: { type: "SureImport" }, headers: @headers
      assert_response :forbidden
    end
  end

  test "guest api keys can still create transaction imports" do
    assert_difference("Import.count", 1) do
      post api_v1_imports_url, params: { type: "TransactionImport", raw_file_content: "date,amount,name\n01/15/2024,5.00,Coffee" }, headers: @headers
    end

    assert_response :created
  end

  private

    def guest_api_key
      ApiKey.create!(
        user: @guest,
        name: "Guest Key #{SecureRandom.hex(4)}",
        key: ApiKey.generate_secure_key,
        scopes: %w[read_write],
        source: "web"
      )
    end
end
