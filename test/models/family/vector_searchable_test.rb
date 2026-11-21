require "test_helper"

class Family::VectorSearchableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @family.update!(vector_store_id: "vs_test")
    @guest = users(:family_member)
  end

  test "search asks for a wider pool and limits only the readable hits it returns" do
    readable = @family.family_documents.create!(filename: "tax.pdf", provider_file_id: "file-tax", status: "ready")
    withheld = @family.family_documents.create!(filename: "stmt.pdf", provider_file_id: "file-stmt", status: "ready",
                                                metadata: { "account_statement_id" => SecureRandom.uuid })
    adapter = stub("adapter")
    adapter.expects(:search).with do |store_id:, max_results:, **|
      store_id == "vs_test" && max_results == 3
    end.returns(VectorStore::Response.new(success?: true, data: [
      { file_id: withheld.provider_file_id, content: "withheld" },
      { file_id: "file-lost", content: "untracked" },
      { file_id: readable.provider_file_id, content: "allowed" }
    ], error: nil))
    @family.stubs(:vector_store_adapter).returns(adapter)
    AccountStatement.stubs(:statement_manager?).with(@guest).returns(false)

    results = @family.search_documents("rent", max_results: 1, user: @guest)

    assert_equal [ "file-tax" ], results.map { _1[:file_id] }
  end

  test "a wider pool is fetched again when withheld hits exhaust the first candidates" do
    readable = @family.family_documents.create!(filename: "tax.pdf", provider_file_id: "file-tax", status: "ready")
    2.times do |i|
      @family.family_documents.create!(filename: "withheld#{i}.pdf", provider_file_id: "file-withheld-#{i}", status: "ready",
                                       metadata: { "account_statement_id" => SecureRandom.uuid })
    end
    withheld = [ "file-withheld-0", "file-withheld-1" ].map { { file_id: _1, content: "withheld" } }
    first = VectorStore::Response.new(success?: true, data: withheld + [ { file_id: "file-lost", content: "untracked" } ], error: nil)
    second = VectorStore::Response.new(success?: true, data: withheld + [ { file_id: readable.provider_file_id, content: "allowed" } ], error: nil)
    limits = []
    adapter = stub("adapter")
    adapter.stubs(:search).with do |store_id:, max_results:, **|
      limits << max_results
      store_id == "vs_test"
    end.returns(first, second)
    @family.stubs(:vector_store_adapter).returns(adapter)
    AccountStatement.stubs(:statement_manager?).with(@guest).returns(false)

    results = @family.search_documents("rent", max_results: 1, user: @guest)

    assert_equal [ "file-tax" ], results.map { _1[:file_id] }
    assert_equal [ 3, 6 ], limits, "the pool widens past the restricted candidates"
  end

  test "a rejected poll enqueue leaves the committed row processing with its file" do
    adapter = stub("adapter")
    adapter.stubs(:upload_file).returns(
      VectorStore::Response.new(success?: true, data: { file_id: "file-1", status: "processing" }, error: nil)
    )
    adapter.expects(:remove_file).never
    @family.stubs(:vector_store_adapter).returns(adapter)
    @family.stubs(:ensure_vector_store!).returns("vs_test")
    VectorStore::IndexStatusJob.stubs(:perform_later).raises(StandardError, "queue down")

    document = nil
    assert_nothing_raised { document = @family.upload_document(file_content: "x", filename: "s.pdf") }
    assert document.persisted?
    assert_equal "processing", document.reload.status

    VectorStore::IndexStatusJob.unstub(:perform_later)
    assert_enqueued_with(job: VectorStore::IndexStatusJob) { document.poll_index_later }
  end

  test "a failed upload cleanup is recorded with its file id for a later retry" do
    adapter = stub("adapter")
    error = VectorStore::UploadCleanupError.new(file_id: "file-lost",
                                                attachment_error: VectorStore::Error.new("attach failed"),
                                                cleanup_error: VectorStore::Error.new("delete failed"))
    adapter.stubs(:upload_file).returns(VectorStore::Response.new(success?: false, data: nil, error:))
    adapter.expects(:remove_file).never
    @family.stubs(:vector_store_adapter).returns(adapter)
    @family.stubs(:ensure_vector_store!).returns("vs_test")

    document = @family.upload_document(file_content: "x", filename: "s.pdf")

    assert document.persisted?
    assert_equal "error", document.status
    assert_equal "file-lost", document.provider_file_id
    assert_equal "VectorStore::Error", document.metadata["cleanup_error"]
  end

  test "deleting a family removes an OpenAI store with the backend that created it" do
    family = Family.create!(name: "Leaving", vector_store_id: "vs-openai")
    family.family_documents.create!(filename: "tax.pdf", provider_file_id: "file-1", status: "ready",
                                    metadata: { "vector_store" => "openai" })
    openai = mock("openai_adapter")
    openai.expects(:delete_store).with(store_id: "vs-openai")
          .returns(VectorStore::Response.new(success?: true, data: nil, error: nil))
    VectorStore::Openai.stubs(:from_config).returns(openai)
    configured = mock("configured_adapter")
    configured.expects(:delete_store).never
    VectorStore::Registry.stubs(:adapter).returns(configured)

    family.destroy!
  end
end
