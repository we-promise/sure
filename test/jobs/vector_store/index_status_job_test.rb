require "test_helper"

# Waiting for an OpenAI vector store to index a document (2e plan, step 8).
class VectorStore::IndexStatusJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(vector_store_id: "vs_abc123")
    @adapter = mock("vector_store_adapter")
    VectorStore::Registry.stubs(:adapter).returns(@adapter)
    @document = @family.family_documents.create!(filename: "bac.pdf", provider_file_id: "file-xyz", status: "pending")
    @document.update_column(:status, "processing")
  end

  test "a document uploaded to an asynchronous store is watched until it settles" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:create_store)
    adapter.expects(:upload_file).returns(VectorStore::Response.new(success?: true, data: { file_id: "file-new", status: "processing" }, error: nil))
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    assert_enqueued_with(job: VectorStore::IndexStatusJob) do
      document = @family.upload_document(file_content: "%PDF", filename: "new.pdf")
      assert_equal "processing", document.status
    end
  end

  test "ready once indexed" do
    expect_status("ready")

    VectorStore::IndexStatusJob.perform_now(@document)

    assert_equal "ready", @document.reload.status
  end

  test "an empty index is unreadable, not ready" do
    expect_status("unreadable")

    VectorStore::IndexStatusJob.perform_now(@document)

    assert_equal "unreadable", @document.reload.status
  end

  test "a failed index is an error with its reason" do
    expect_status("error", error: "bad file")

    VectorStore::IndexStatusJob.perform_now(@document)

    assert_equal "error", @document.reload.status
    assert_equal "bad file", @document.metadata["error"]
  end

  test "still indexing looks again later, and gives up after MAX_POLLS" do
    expect_status("processing")
    assert_enqueued_with(job: VectorStore::IndexStatusJob, args: [ @document, 2 ]) { VectorStore::IndexStatusJob.perform_now(@document) }

    expect_status("processing")
    VectorStore::IndexStatusJob.perform_now(@document, VectorStore::IndexStatusJob::MAX_POLLS)
    assert_equal "error", @document.reload.status
  end

  test "deleting the family deletes its store" do
    @adapter.expects(:delete_store).with(store_id: "vs_abc123").returns(VectorStore::Response.new(success?: true, data: nil, error: nil))

    @family.send(:delete_vector_store)
  end

  private
    def expect_status(status, error: nil)
      @adapter.expects(:file_status).with(store_id: "vs_abc123", file_id: "file-xyz")
              .returns(VectorStore::Response.new(success?: true, data: { status:, error: }.compact, error: nil))
    end
end
