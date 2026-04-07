require "test_helper"

class ActiveStorageAuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @user_a = users(:family_admin) # In dylan_family
    @user_b = users(:empty) # In empty family

    @transaction_a = transactions(:one) # Assuming it belongs to dylan_family via its entry/account
    @transaction_a.attachments.attach(
      io: StringIO.new("Family A Secret Receipt"),
      filename: "receipt.pdf",
      content_type: "application/pdf"
    )
    @attachment_a = @transaction_a.attachments.first
  end

  test "user can access attachments within their own family" do
    sign_in @user_a

    # Get the redirect URL from our controller
    get transaction_attachment_path(@transaction_a, @attachment_a)
    assert_response :redirect

    # Follow the redirect to ActiveStorage::Blobs::RedirectController
    follow_redirect!

    # In test/local environment, it will redirect again to a disk URL
    assert_response :redirect
    assert_match(/rails\/active_storage\/disk/, response.header["Location"])
  end

  test "user cannot access attachments from a different family" do
    sign_in @user_b

    # Even if they find the signed global ID (which is hard but possible),
    # the monkey patch should block them at the blob controller level.
    # We bypass our controller and go straight to the blob serving URL to test the security layer
    get rails_blob_path(@attachment_a)

    # The monkey patch raises ActiveRecord::RecordNotFound which rails converts to 404
    assert_response :not_found
  end

  test "user cannot access variants from a different family" do
    # Attach an image to test variants
    file = File.open(Rails.root.join("test/fixtures/files/square-placeholder.png"))
    @transaction_a.attachments.attach(io: file, filename: "test.png", content_type: "image/png")
    attachment = @transaction_a.attachments.last
    variant = attachment.variant(resize_to_limit: [ 100, 100 ]).processed

    sign_in @user_b

    # Straight to the representation URL
    get rails_representation_path(variant)

    assert_response :not_found
  end
end
