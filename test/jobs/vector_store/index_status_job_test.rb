require "test_helper"

# Waiting for an OpenAI vector store to index a document.
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

  test "a status request that fails leaves the document processing and polls again, then records the outcome" do
    @adapter.expects(:file_status).returns(VectorStore::Response.new(success?: false, data: nil, error: VectorStore::Error.new("503")))
    assert_enqueued_with(job: VectorStore::IndexStatusJob, args: [ @document, 2 ]) { VectorStore::IndexStatusJob.perform_now(@document) }
    assert_equal "processing", @document.reload.status

    expect_status("ready")
    VectorStore::IndexStatusJob.perform_now(@document, 2)
    assert_equal "ready", @document.reload.status
  end

  test "deleting the family deletes its store" do
    @adapter.expects(:delete_store).with(store_id: "vs_abc123").returns(VectorStore::Response.new(success?: true, data: nil, error: nil))

    @family.send(:delete_vector_store)
  end

  test "an unavailable backend that accepted the document errors instead of calling it ready" do
    @document.update_column(:metadata, { "vector_store" => "openai" })
    @adapter.expects(:file_status).never
    VectorStore::Openai.stubs(:from_config).returns(nil)

    VectorStore::IndexStatusJob.perform_now(@document)

    assert_equal "error", @document.reload.status
    assert_match(/openai/, @document.metadata["error"])
  end

  test "polls with the backend that accepted the document, not the configured one" do
    @document.update_column(:metadata, { "vector_store" => "openai" })
    openai = mock("openai_adapter")
    openai.expects(:file_status).with(store_id: "vs_abc123", file_id: "file-xyz")
          .returns(VectorStore::Response.new(success?: true, data: { status: "ready" }, error: nil))
    VectorStore::Openai.stubs(:from_config).returns(openai)
    @adapter.expects(:file_status).never

    VectorStore::IndexStatusJob.perform_now(@document)

    assert_equal "ready", @document.reload.status
  end

  # A second poll can finish the index while an older one is between its HTTP call and its write.
  test "a late error poll cannot overwrite a document already ready" do
    expect_concurrent_status("ready", "error", error: "bad file")

    VectorStore::IndexStatusJob.perform_now(@document)

    assert_equal "ready", @document.reload.status
  end

  test "a late poll-cap failure cannot overwrite a document already ready" do
    expect_concurrent_status("ready", "processing")

    VectorStore::IndexStatusJob.perform_now(@document, VectorStore::IndexStatusJob::MAX_POLLS)

    assert_equal "ready", @document.reload.status
  end

  test "a rejected requeue leaves the document processing and recoverable" do
    expect_status("processing")
    enqueuer = stub("job_enqueuer")
    enqueuer.stubs(:perform_later).raises(StandardError, "queue down")
    VectorStore::IndexStatusJob.stubs(:set).returns(enqueuer)

    assert_nothing_raised { VectorStore::IndexStatusJob.perform_now(@document) }
    assert_equal "processing", @document.reload.status

    VectorStore::IndexStatusJob.unstub(:set)
    assert_enqueued_with(job: VectorStore::IndexStatusJob) { VectorStore::RequeueIndexPollsJob.perform_now }
  end

  private
    def expect_concurrent_status(concurrent_status, reported_status, error: nil)
      adapter = stub("vector_store_adapter")
      document = @document
      adapter.define_singleton_method(:file_status) do |**_args|
        FamilyDocument.find(document.id).update_column(:status, concurrent_status)
        VectorStore::Response.new(success?: true, data: { status: reported_status, error: }.compact, error: nil)
      end
      VectorStore::Registry.stubs(:adapter).returns(adapter)
    end

    def expect_status(status, error: nil)
      @adapter.expects(:file_status).with(store_id: "vs_abc123", file_id: "file-xyz")
              .returns(VectorStore::Response.new(success?: true, data: { status:, error: }.compact, error: nil))
    end
end
