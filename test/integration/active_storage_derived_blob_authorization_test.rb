require "test_helper"

# Receipts follow account sharing, and variant/preview blobs follow the blob they were made from.
class ActiveStorageDerivedBlobAuthorizationTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @outsider = users(:empty)

    @receipt_transaction = transactions(:one) # depository, shared with family_member
    @receipt = attach_image(@receipt_transaction)
  end

  test "member cannot access a receipt on an account that is not shared with them" do
    entry = create_transaction(account: accounts(:other_asset))
    receipt = attach_pdf(entry.transaction)

    sign_in @member
    get rails_blob_path(receipt)

    assert_response :not_found
  end

  test "member can access a receipt on an account shared with them" do
    sign_in @member
    get rails_blob_path(@receipt)

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "tracked variant disk urls follow the source receipt" do
    disk_url = disk_url_for(rails_representation_path(@receipt.variant(resize_to_limit: [ 50, 50 ])))

    sign_in @outsider
    get disk_url
    assert_response :not_found

    sign_out @outsider
    sign_in @owner
    get disk_url
    assert_response :success
  end

  test "tracked variant blobs follow the source receipt" do
    variant = @receipt.variant(resize_to_limit: [ 50, 50 ]).processed
    variant_blob = variant.image.blob

    sign_in @outsider
    get rails_blob_path(variant_blob)
    assert_response :not_found

    sign_out @outsider
    sign_in @owner
    get rails_blob_path(variant_blob)
    assert_response :redirect
  end

  test "member cannot access previews of a receipt on an account that is not shared with them" do
    entry = create_transaction(account: accounts(:other_asset))
    preview = attach_preview(attach_pdf(entry.transaction).blob)
    variant_blob = preview.variant(resize_to_limit: [ 20, 20 ]).processed.image.blob

    sign_in @member
    get rails_blob_path(preview)
    assert_response :not_found

    get rails_blob_path(variant_blob)
    assert_response :not_found
  end

  test "member can access previews of a receipt on an account shared with them" do
    preview = attach_preview(attach_pdf(@receipt_transaction).blob)

    sign_in @member
    get rails_blob_path(preview)

    assert_response :redirect
  end

  test "preview images follow the source receipt" do
    receipt = attach_pdf(@receipt_transaction)
    preview = attach_preview(receipt.blob)

    sign_in @outsider
    get rails_blob_path(preview)
    assert_response :not_found

    sign_out @outsider
    sign_in @owner
    get rails_blob_path(preview)
    assert_response :redirect
  end

  test "variants of preview images follow the source receipt" do
    receipt = attach_pdf(@receipt_transaction)
    preview = attach_preview(receipt.blob)
    variant_blob = preview.variant(resize_to_limit: [ 20, 20 ]).processed.image.blob

    sign_in @outsider
    get rails_blob_path(variant_blob)
    assert_response :not_found

    sign_out @outsider
    sign_in @owner
    get rails_blob_path(variant_blob)
    assert_response :redirect
  end

  test "disk urls fail closed once the blob row is gone" do
    blob = @receipt.blob
    disk_url = ActiveStorage::Current.set(url_options: { host: "www.example.com" }) { blob.url }
    # Drop the rows but keep the file, as between a purge and its file deletion.
    ActiveStorage::Attachment.where(id: @receipt.id).delete_all
    ActiveStorage::Blob.where(id: blob.id).delete_all
    assert ActiveStorage::Blob.service.exist?(blob.key)

    sign_in @owner
    get disk_url

    assert_response :not_found
  end

  test "preview images of unattached blobs fail closed" do
    source = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("%PDF-1.4 orphan"),
      filename: "orphan.pdf",
      content_type: "application/pdf"
    )
    preview = attach_preview(source)

    sign_in @owner
    get rails_blob_path(preview)

    assert_response :not_found
  end

  private

    def attach_image(transaction)
      transaction.attachments.attach(
        io: File.open(Rails.root.join("test/fixtures/files/square-placeholder.png")),
        filename: "receipt.png",
        content_type: "image/png"
      )
      transaction.attachments.last
    end

    def attach_pdf(transaction)
      transaction.attachments.attach(
        io: StringIO.new("%PDF-1.4 Secret Receipt"),
        filename: "receipt.pdf",
        content_type: "application/pdf"
      )
      transaction.attachments.last
    end

    def attach_preview(blob)
      blob.preview_image.attach(
        io: File.open(Rails.root.join("test/fixtures/files/square-placeholder.png")),
        filename: "receipt.png",
        content_type: "image/png"
      )
      blob.preview_image
    end

    def sign_out(user)
      user.sessions.destroy_all
    end

    # The representation route redirects to the variant's own disk url.
    def disk_url_for(representation_path)
      sign_in @owner
      get representation_path
      assert_response :redirect
      url = response.location
      assert_match(/rails\/active_storage\/disk/, url)
      sign_out @owner
      url
    end
end
