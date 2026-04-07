require "test_helper"

class TransactionAttachmentValidationTest < ActiveSupport::TestCase
  setup do
    @transaction = transactions(:one)
  end

  test "should validate attachment content types" do
    # Valid content type should pass
    @transaction.attachments.attach(
      io: StringIO.new("valid content"),
      filename: "test.pdf",
      content_type: "application/pdf"
    )
    assert @transaction.valid?

    # Invalid content type should fail
    @transaction.attachments.attach(
      io: StringIO.new("invalid content"),
      filename: "test.txt",
      content_type: "text/plain"
    )
    assert_not @transaction.valid?
    assert_includes @transaction.errors.full_messages_for(:attachments).join, "unsupported format"
  end

  test "should validate attachment count limit" do
    # Fill up to the limit
    Transaction::MAX_ATTACHMENTS_PER_TRANSACTION.times do |i|
      @transaction.attachments.attach(
        io: StringIO.new("content #{i}"),
        filename: "file#{i}.pdf",
        content_type: "application/pdf"
      )
    end
    assert @transaction.valid?

    # Exceeding the limit should fail
    @transaction.attachments.attach(
      io: StringIO.new("extra content"),
      filename: "extra.pdf",
      content_type: "application/pdf"
    )
    assert_not @transaction.valid?
    assert_includes @transaction.errors.full_messages_for(:attachments).join, "cannot exceed"
  end

  test "should validate attachment file size" do
    # Create a mock large attachment
    large_content = "x" * (Transaction::MAX_ATTACHMENT_SIZE + 1)

    @transaction.attachments.attach(
      io: StringIO.new(large_content),
      filename: "large.pdf",
      content_type: "application/pdf"
    )

    assert_not @transaction.valid?
    assert_includes @transaction.errors.full_messages_for(:attachments).join, "too large"
  end
end
