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

  test "orphaned transaction attachment fails closed" do
    @attachment_a.update_columns(record_id: SecureRandom.uuid)

    sign_in @user_a

    get rails_blob_path(@attachment_a)

    assert_response :not_found
  end

  private

    def uploaded_file(filename:, content_type:, content:)
      tempfile = Tempfile.new([ File.basename(filename, ".*"), File.extname(filename) ])
      tempfile.binmode
      tempfile.write(content)
      tempfile.rewind

      ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: filename,
        type: content_type
      )
    end

    def family_guest
      @family_guest ||= @user_a.family.users.create!(
        first_name: "Readonly",
        last_name: "Guest",
        email: "storage-guest@example.com",
        password: user_password_test,
        role: "guest",
        onboarded_at: Time.current,
        ui_layout: "dashboard"
      )
    end
end
