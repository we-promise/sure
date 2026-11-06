require "test_helper"

# The OpenAI vector store adapter with the spike's fixes (2e plan, step 8), against WebMock: the
# client from Ai::Transport::Http, the original filename, indexing status, deleting files with the
# document and the store, and the score threshold.
class VectorStore::OpenaiTest < ActiveSupport::TestCase
  BASE = "https://api.openai.example.test/v1".freeze
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  setup do
    @endpoint = ai_endpoint(name: "openai", base_url: BASE, api_key: "sk-test-key", vector_store: true,
                            extra_headers: { "X-Team" => "finance" })
    @adapter = VectorStore::Openai.new(endpoint: @endpoint)
  end

  test "create_store goes through Ai::Transport::Http's client, with the endpoint's key and headers" do
    stub_json(:post, "/vector_stores", { id: "vs_abc123" })

    response = @adapter.create_store(name: "Test Store")

    assert response.success?
    assert_equal "vs_abc123", response.data[:id]
    assert_requested(:post, "#{BASE}/vector_stores", headers: { "Authorization" => "Bearer sk-test-key", "X-Team" => "finance" })
  end

  test "upload_file uploads under the document's own filename and answers processing" do
    upload = stub_request(:post, "#{BASE}/files").with { _1.body.include?('filename="bac statement.pdf"') }
                                                  .to_return(status: 200, headers: JSON_HEADERS, body: { id: "file-xyz" }.to_json)
    stub_json(:post, "/vector_stores/vs_abc123/files", { id: "file-xyz", status: "in_progress" })

    response = @adapter.upload_file(store_id: "vs_abc123", file_content: "%PDF-1.4", filename: "../bac statement.pdf")

    assert response.success?
    assert_equal({ file_id: "file-xyz", status: "processing" }, response.data)
    assert_requested upload
  end

  test "a file that can't be attached to the store is deleted again" do
    stub_json(:post, "/files", { id: "file-xyz" })
    stub_request(:post, "#{BASE}/vector_stores/vs_abc123/files").to_return(status: 500, body: "boom")
    delete = stub_json(:delete, "/files/file-xyz", { deleted: true })

    assert_not @adapter.upload_file(store_id: "vs_abc123", file_content: "x", filename: "a.txt").success?
    assert_requested delete
  end

  test "file_status: ready, unreadable for an empty index, processing, or error" do
    { { status: "completed", usage_bytes: 2048 } => "ready", { status: "completed", usage_bytes: 0 } => "unreadable",
      { status: "in_progress" } => "processing", { status: "failed", last_error: { message: "bad file" } } => "error" }.each do |file, expected|
      WebMock.reset!
      stub_json(:get, "/vector_stores/vs_abc123/files/file-xyz", { id: "file-xyz", **file })

      assert_equal expected, @adapter.file_status(store_id: "vs_abc123", file_id: "file-xyz").data[:status]
    end
  end

  test "remove_file detaches the file and deletes it from the Files API" do
    detach = stub_json(:delete, "/vector_stores/vs_abc123/files/file-xyz", { deleted: true })
    delete = stub_json(:delete, "/files/file-xyz", { deleted: true })

    assert @adapter.remove_file(store_id: "vs_abc123", file_id: "file-xyz").success?
    assert_requested detach
    assert_requested delete
  end

  test "delete_store deletes every file it holds, then the store" do
    stub_request(:get, "#{BASE}/vector_stores/vs_abc123/files?limit=100")
      .to_return(status: 200, headers: JSON_HEADERS, body: { data: [ { id: "file-1" } ], has_more: true }.to_json)
    stub_request(:get, "#{BASE}/vector_stores/vs_abc123/files?limit=100&after=file-1")
      .to_return(status: 200, headers: JSON_HEADERS, body: { data: [ { id: "file-2" } ], has_more: false }.to_json)
    deletes = %w[file-1 file-2].map { stub_json(:delete, "/files/#{_1}", { deleted: true }) }
    store = stub_json(:delete, "/vector_stores/vs_abc123", { deleted: true })

    assert @adapter.delete_store(store_id: "vs_abc123").success?
    deletes.each { assert_requested _1 }
    assert_requested store
  end

  test "search asks for a score threshold and drops anything under it" do
    search = stub_request(:post, "#{BASE}/vector_stores/vs_abc123/search")
               .with { JSON.parse(_1.body).dig("ranking_options", "score_threshold") == VectorStore::Openai::MIN_SCORE }
               .to_return(status: 200, headers: JSON_HEADERS, body: { data: [
                 { file_id: "file-1", filename: "bac.pdf", score: 0.84, content: [ { type: "text", text: "rent" } ] },
                 { file_id: "file-2", filename: "impact.pdf", score: 0.14, content: [ { type: "text", text: "payroll" } ] }
               ] }.to_json)

    response = @adapter.search(store_id: "vs_abc123", query: "monthly apartment rent payment", max_results: 5)

    assert_requested search
    assert_equal [ { content: "rent", filename: "bac.pdf", score: 0.84, file_id: "file-1" } ], response.data
  end

  test "wraps errors in a failure response" do
    stub_request(:post, "#{BASE}/vector_stores").to_return(status: 500, body: "boom")

    response = @adapter.create_store(name: "x")

    assert_not response.success?
    assert_kind_of VectorStore::Error, response.error
  end

  private
    def stub_json(method, path, body)
      stub_request(method, "#{BASE}#{path}").to_return(status: 200, headers: JSON_HEADERS, body: body.to_json)
    end
end
