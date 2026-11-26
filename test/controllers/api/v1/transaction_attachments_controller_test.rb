# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionAttachmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(user: @user, name: "Read key", scopes: [ "read" ], display_key: "test_read_#{SecureRandom.hex(8)}", source: "mobile")
    @transaction = transactions(:one)
    @transaction.attachments.attach(io: file_fixture("receipts/rotated.jpg").open, filename: "receipt.jpg", content_type: "image/jpeg")
    @attachment = @transaction.attachments.first
  end

  teardown do
    redis = Redis.new
    redis.del("api_rate_limit:#{@api_key.id}")
    redis.close
  end

  test "streams the attachment to an API client" do
    get api_v1_transaction_attachment_url(@transaction, @attachment), headers: api_headers(@api_key)

    assert_response :success
    assert_equal "image/jpeg", response.media_type
    assert_equal @attachment.download.bytesize, response.body.bytesize
  end

  test "streams a thumbnail" do
    get api_v1_transaction_attachment_url(@transaction, @attachment, variant: "thumbnail"), headers: api_headers(@api_key)

    assert_response :success
    assert_operator response.body.bytesize, :<, @attachment.download.bytesize
  end

  test "requires authentication" do
    get api_v1_transaction_attachment_url(@transaction, @attachment)

    assert_response :unauthorized
  end

  test "404 for another family's transaction" do
    other = users(:empty)
    other.api_keys.active.destroy_all
    other_key = ApiKey.create!(user: other, name: "Other", scopes: [ "read" ], display_key: "test_other_#{SecureRandom.hex(8)}", source: "mobile")

    get api_v1_transaction_attachment_url(@transaction, @attachment), headers: api_headers(other_key)

    assert_response :not_found
  ensure
    Redis.new.tap { _1.del("api_rate_limit:#{other_key&.id}") }.close
  end

  test "transaction JSON links attachments to this endpoint" do
    get api_v1_transaction_url(@transaction), headers: api_headers(@api_key)

    attachment = JSON.parse(response.body)["attachments"].first
    assert_equal api_v1_transaction_attachment_url(@transaction, @attachment), attachment["url"]
    assert_equal api_v1_transaction_attachment_url(@transaction, @attachment, variant: "thumbnail"), attachment["thumbnail_url"]
  end
end
