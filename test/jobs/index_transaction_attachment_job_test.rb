require "test_helper"

class IndexTransactionAttachmentJobTest < ActiveJob::TestCase
  setup do
    @entry = entries(:transaction)
    @transaction = @entry.entryable
    @family = @transaction.entry.account.family
  end

  test "uploads a supported attachment to the family vector store" do
    VectorStore.stubs(:configured?).returns(true)
    blob = attach!("receipt.pdf", "application/pdf")

    Family.any_instance.expects(:upload_document).with do |file_content:, filename:, metadata:|
      assert_equal "receipt.pdf", filename
      assert_equal "transaction_attachment", metadata["type"]
      assert_equal @transaction.id, metadata["transaction_id"]
      assert_equal blob.id.to_s, metadata["attachment_blob_id"]
      true
    end.returns(family_documents(:tax_return))

    IndexTransactionAttachmentJob.perform_now(@transaction, blob)
  end

  test "does nothing when the vector store is not configured" do
    VectorStore.stubs(:configured?).returns(false)
    blob = attach!("receipt.pdf", "application/pdf")

    Family.any_instance.expects(:upload_document).never

    IndexTransactionAttachmentJob.perform_now(@transaction, blob)
  end

  test "skips attachments with unsupported extensions" do
    VectorStore.stubs(:configured?).returns(true)
    blob = attach!("photo.webp", "image/webp")

    Family.any_instance.expects(:upload_document).never

    IndexTransactionAttachmentJob.perform_now(@transaction, blob)
  end

  test "does not re-upload an attachment that is already indexed" do
    VectorStore.stubs(:configured?).returns(true)
    blob = attach!("receipt.pdf", "application/pdf")

    @family.family_documents.create!(
      filename: "receipt.pdf",
      content_type: "application/pdf",
      file_size: 10,
      provider_file_id: "file-existing",
      status: "ready",
      metadata: { "attachment_blob_id" => blob.id.to_s }
    )

    Family.any_instance.expects(:upload_document).never

    IndexTransactionAttachmentJob.perform_now(@transaction, blob)
  end

  private

    def attach!(filename, content_type)
      @transaction.attachments.attach(
        io: StringIO.new("file-bytes"),
        filename: filename,
        content_type: content_type
      )
      @transaction.attachments.find { |a| a.filename.to_s == filename }.blob
    end
end
