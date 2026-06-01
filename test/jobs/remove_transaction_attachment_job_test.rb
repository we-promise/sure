require "test_helper"

class RemoveTransactionAttachmentJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "removes the indexed document matching the purged blob id" do
    VectorStore.stubs(:configured?).returns(true)

    document = @family.family_documents.create!(
      filename: "receipt.pdf",
      content_type: "application/pdf",
      file_size: 10,
      provider_file_id: "file-123",
      status: "ready",
      metadata: { "attachment_blob_id" => "555" }
    )

    @family.expects(:remove_document).with(document).returns(true)

    RemoveTransactionAttachmentJob.perform_now(@family, 555)
  end

  test "does nothing when the vector store is not configured" do
    VectorStore.stubs(:configured?).returns(false)

    @family.expects(:remove_document).never

    RemoveTransactionAttachmentJob.perform_now(@family, 555)
  end

  test "does nothing when no document matches the blob id" do
    VectorStore.stubs(:configured?).returns(true)

    @family.expects(:remove_document).never

    RemoveTransactionAttachmentJob.perform_now(@family, 999)
  end
end
