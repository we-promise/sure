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
