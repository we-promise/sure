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
