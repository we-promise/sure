require "test_helper"

class TransactionAttachmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
    @transaction = @entry.entryable
  end

  test "should upload attachment to transaction" do
    file = fixture_file_upload("test.txt", "text/plain")

    assert_difference "@transaction.attachments.count", 1 do
      post transaction_attachments_path(@transaction), params: { attachment: file }
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "Attachment uploaded successfully", flash[:notice]
  end

  test "should upload multiple attachments to transaction" do
    file1 = fixture_file_upload("test.txt", "text/plain")
    file2 = fixture_file_upload("test.txt", "text/plain")

    assert_difference "@transaction.attachments.count", 2 do
      post transaction_attachments_path(@transaction), params: { attachments: [file1, file2] }
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "2 attachments uploaded successfully", flash[:notice]
  end

  test "should handle upload with no files" do
    assert_no_difference "@transaction.attachments.count" do
      post transaction_attachments_path(@transaction), params: {}
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "No files selected for upload", flash[:alert]
  end

  test "should show attachment for authorized user" do
    @transaction.attachments.attach(
      io: StringIO.new("test content"),
      filename: "test.txt",
      content_type: "text/plain"
    )

    attachment = @transaction.attachments.first
    get transaction_attachment_path(@transaction, attachment)

    assert_response :redirect
  end

  test "should delete attachment" do
    @transaction.attachments.attach(
      io: StringIO.new("test content"),
      filename: "test.txt",
      content_type: "text/plain"
    )

    attachment = @transaction.attachments.first

    assert_difference "@transaction.attachments.count", -1 do
      delete transaction_attachment_path(@transaction, attachment)
    end

    assert_redirected_to transaction_path(@transaction)
  end
end
