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

    @statement_a = AccountStatement.create_from_upload!(
      family: @user_a.family,
      account: @transaction_a.entry.account,
      file: uploaded_file(
        filename: "statement.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 Family A Secret Statement"
      )
    )
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

  test "disk service urls require authentication" do
    sign_in @user_a

    get rails_blob_path(@statement_a.original_file)
    assert_response :redirect
    disk_url = response.location
    sign_out @user_a

    get disk_url

    assert_redirected_to new_session_url
  end

  test "disk service urls enforce statement blob authorization" do
    sign_in @user_a

    get rails_blob_path(@statement_a.original_file)
    assert_response :redirect
    disk_url = response.location
    sign_out @user_a
    sign_in @user_b

    get disk_url

    assert_response :not_found
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

  test "user cannot access statement blob from a different family" do
    sign_in @user_b

    get rails_blob_path(@statement_a.original_file)

    assert_response :not_found
  end

  test "unauthenticated user is redirected before statement blob access" do
    get rails_blob_path(@statement_a.original_file)

    assert_redirected_to new_session_url
  end

  test "user cannot access linked statement blob for an inaccessible account" do
    private_account = accounts(:other_asset)
    statement = AccountStatement.create_from_upload!(
      family: @user_a.family,
      account: private_account,
      file: uploaded_file(
        filename: "private_statement.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 Private Family Statement"
      )
    )

    sign_in users(:family_member)

    get rails_blob_path(statement.original_file)

    assert_response :not_found
  end

  test "user can access linked statement blob for a shared account" do
    statement = AccountStatement.create_from_upload!(
      family: @user_a.family,
      account: accounts(:credit_card),
      file: uploaded_file(
        filename: "shared_statement.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 Shared Family Statement"
      )
    )

    sign_in users(:family_member)

    get rails_blob_path(statement.original_file)

    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_match(/rails\/active_storage\/disk/, request.path)
  end

  test "guest cannot access unmatched statement blob" do
    statement = AccountStatement.create_from_upload!(
      family: @user_a.family,
      account: nil,
      file: uploaded_file(
        filename: "unmatched_statement.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 Unmatched Family Statement"
      )
    )

    sign_in family_guest

    get rails_blob_path(statement.original_file)

    assert_response :not_found
  end

  test "orphaned statement attachment fails closed" do
    attachment = @statement_a.original_file.attachment
    attachment.update_columns(record_id: SecureRandom.uuid)

    sign_in @user_a

    get rails_blob_path(attachment)

    assert_response :not_found
  end

  test "unattached blobs fail closed" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("unattached statement"),
      filename: "unattached.csv",
      content_type: "text/csv"
    )

    sign_in @user_a

    get rails_blob_path(blob)

    assert_response :not_found
  end

  test "blob authorization checks protected attachments even when blob is also attached elsewhere" do
    document = FamilyDocument.create!(family: @user_a.family, filename: "shared.pdf", status: "ready")
    document.file.attach(@statement_a.original_file.blob)

    sign_in @user_b

    get rails_blob_path(document.file)

    assert_response :not_found
  end

  test "blob authorization denies when any protected attachment is unauthorized" do
    statement_b = AccountStatement.new(
      family: @user_b.family,
      filename: "shared_statement.pdf",
      content_type: @statement_a.content_type,
      byte_size: @statement_a.byte_size,
      checksum: @statement_a.checksum,
      content_sha256: @statement_a.content_sha256,
      currency: @user_b.family.currency
    )
    statement_b.original_file.attach(@statement_a.original_file.blob)
    statement_b.save!

    sign_in @user_a

    get rails_blob_path(@statement_a.original_file)

    assert_response :not_found
  end

  test "unknown protected attachment types fail closed" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("unknown protected attachment"),
      filename: "unknown.csv",
      content_type: "text/csv"
    )
    ActiveStorage::Attachment.insert!(
      {
      name: "file",
      record_type: "ProtectedAttachmentProbe",
      record_id: SecureRandom.uuid,
      blob_id: blob.id,
      created_at: Time.current
      }
    )

    with_protected_record_types("Transaction", "AccountStatement", "ProtectedAttachmentProbe") do
      sign_in @user_a

      get rails_blob_path(blob)

      assert_response :not_found
    end
  end

  test "direct uploads require authentication" do
    post rails_direct_uploads_path, params: {
      blob: {
        filename: "statement.csv",
        byte_size: 1,
        checksum: Digest::MD5.base64digest("1"),
        content_type: "text/csv"
      }
    }, as: :json

    assert_redirected_to new_session_url
  end

  test "authenticated direct uploads can create unattached blobs" do
    sign_in @user_a

    post rails_direct_uploads_path, params: {
      blob: {
        filename: "statement.csv",
        byte_size: 1,
        checksum: Digest::MD5.base64digest("1"),
        content_type: "text/csv"
      }
    }, as: :json

    assert_response :success
    assert response.parsed_body["signed_id"].present?
  end

  test "orphaned transaction attachment fails closed" do
    @attachment_a.update_columns(record_id: SecureRandom.uuid)

    sign_in @user_a

    get rails_blob_path(@attachment_a)

    assert_response :not_found
  end

  private

    def sign_out(user)
      user.sessions.each { |session| delete session_path(session) }
    end

    def with_protected_record_types(*types)
      previous_types = ActiveStorageAttachmentAuthorization::PROTECTED_RECORD_TYPES
      ActiveStorageAttachmentAuthorization.send(:remove_const, :PROTECTED_RECORD_TYPES)
      ActiveStorageAttachmentAuthorization.const_set(:PROTECTED_RECORD_TYPES, types.flatten.freeze)

      yield
    ensure
      ActiveStorageAttachmentAuthorization.send(:remove_const, :PROTECTED_RECORD_TYPES)
      ActiveStorageAttachmentAuthorization.const_set(:PROTECTED_RECORD_TYPES, previous_types)
    end
end
