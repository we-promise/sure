require "test_helper"

class TransactionAttachmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
    @transaction = @entry.entryable
  end

  test "should upload attachment to transaction" do
    file = fixture_file_upload("test.txt", "application/pdf")

    assert_difference "@transaction.attachments.count", 1 do
      post transaction_attachments_path(@transaction), params: { attachment: file }
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "Attachment uploaded successfully", flash[:notice]
  end

  test "should upload multiple attachments to transaction" do
    file1 = fixture_file_upload("test.txt", "application/pdf")
    file2 = fixture_file_upload("test.txt", "image/jpeg")

    assert_difference "@transaction.attachments.count", 2 do
      post transaction_attachments_path(@transaction), params: { attachments: [ file1, file2 ] }
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "2 attachments uploaded successfully", flash[:notice]
  end

  test "should ignore blank attachments in array" do
    file = fixture_file_upload("test.txt", "application/pdf")

    assert_difference "@transaction.attachments.count", 1 do
      # Simulate Rails behavior where an empty string is often sent in the array
      post transaction_attachments_path(@transaction), params: { attachments: [ file, "" ] }
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "Attachment uploaded successfully", flash[:notice] # Should be singular
  end

  test "should handle upload with no files" do
    assert_no_difference "@transaction.attachments.count" do
      post transaction_attachments_path(@transaction), params: {}
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "No files selected for upload", flash[:alert]
  end

  test "should reject unsupported file types" do
    file = fixture_file_upload("test.txt", "text/plain")

    assert_no_difference "@transaction.attachments.count" do
      post transaction_attachments_path(@transaction), params: { attachment: file }
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "unsupported format", flash[:alert]
  end

  test "should reject exceeding attachment count limit" do
    # Fill up to the limit
    (Transaction::MAX_ATTACHMENTS_PER_TRANSACTION).times do |i|
      @transaction.attachments.attach(
        io: StringIO.new("content #{i}"),
        filename: "file#{i}.pdf",
        content_type: "application/pdf"
      )
    end

    file = fixture_file_upload("test.txt", "application/pdf")

    assert_no_difference "@transaction.attachments.count" do
      post transaction_attachments_path(@transaction), params: { attachment: file }
    end

    assert_redirected_to transaction_path(@transaction)
    assert_match "Cannot exceed #{Transaction::MAX_ATTACHMENTS_PER_TRANSACTION} attachments", flash[:alert]
  end

  test "should show attachment for authorized user" do
    @transaction.attachments.attach(
      io: StringIO.new("test content"),
      filename: "test.pdf",
      content_type: "application/pdf"
    )

    attachment = @transaction.attachments.first
    get transaction_attachment_path(@transaction, attachment)

    assert_response :redirect
  end

  test "should upload attachment via turbo_stream" do
    file = fixture_file_upload("test.txt", "application/pdf")

    assert_difference "@transaction.attachments.count", 1 do
      post transaction_attachments_path(@transaction), params: { attachment: file }, as: :turbo_stream
    end

    assert_response :success
    assert_match(/turbo-stream action="replace" target="transaction_attachments_#{@transaction.id}"/, response.body)
    assert_match(/turbo-stream action="append" target="notification-tray"/, response.body)
    assert_match("Attachment uploaded successfully", response.body)
  end

  test "should show attachment inline" do
    @transaction.attachments.attach(io: StringIO.new("test"), filename: "test.pdf", content_type: "application/pdf")
    attachment = @transaction.attachments.first

    get transaction_attachment_path(@transaction, attachment, disposition: :inline)

    assert_response :redirect
    assert_match(/disposition=inline/, response.redirect_url)
  end

  test "should show attachment as download" do
    @transaction.attachments.attach(io: StringIO.new("test"), filename: "test.pdf", content_type: "application/pdf")
    attachment = @transaction.attachments.first

    get transaction_attachment_path(@transaction, attachment, disposition: :attachment)

    assert_response :redirect
    assert_match(/disposition=attachment/, response.redirect_url)
  end

  test "should delete attachment via turbo_stream" do
    @transaction.attachments.attach(io: StringIO.new("test"), filename: "test.pdf", content_type: "application/pdf")
    attachment = @transaction.attachments.first

    assert_difference "@transaction.attachments.count", -1 do
      delete transaction_attachment_path(@transaction, attachment), as: :turbo_stream
    end

    assert_response :success
    assert_match(/turbo-stream action="replace" target="transaction_attachments_#{@transaction.id}"/, response.body)
    assert_match(/turbo-stream action="append" target="notification-tray"/, response.body)
    assert_match("Attachment deleted successfully", response.body)
  end
end
