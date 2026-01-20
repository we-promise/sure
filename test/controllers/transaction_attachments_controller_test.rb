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
