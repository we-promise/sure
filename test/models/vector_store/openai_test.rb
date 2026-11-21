require "test_helper"

# The OpenAI vector store adapter with the spike's fixes, against WebMock: the
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

  test "a store is reached on the server that created it, whichever route embeds now" do
    other = ai_endpoint(name: "embed", base_url: "https://embed.example.test/v1", api_key: "k2", vector_store: true)
    Ai::Config.stubs(:current).returns(Ai::Config.new(endpoints: [ other, @endpoint ]))

    assert_equal BASE, VectorStore::Openai.for_store("#{BASE}/").endpoint_url
    assert_nil VectorStore::Openai.for_store("https://gone.example.test/v1"), "never another server"
  end

  test "an endpoint without a URL records OpenAI's default, and is found by it" do
    hosted = ai_endpoint(name: "openai", base_url: nil, api_key: "sk-test-key", vector_store: true)
    Ai::Config.stubs(:current).returns(Ai::Config.new(endpoints: [ hosted ]))

    recorded = VectorStore::Openai.new(endpoint: hosted).endpoint_url

    assert_equal "https://api.openai.com/v1", recorded
    assert VectorStore::Openai.for_store(recorded)
  end

  test "a gateway path keeps its case when a store's server is matched" do
    upper = ai_endpoint(name: "team_a", base_url: "https://gw.example.test/TeamA/v1", api_key: "a", vector_store: true)
    lower = ai_endpoint(name: "team_b", base_url: "https://gw.example.test/teama/v1", api_key: "b", vector_store: true)
    Ai::Config.stubs(:current).returns(Ai::Config.new(endpoints: [ lower, upper ]))

    assert_equal "https://gw.example.test/TeamA/v1", VectorStore::Openai.for_store("https://GW.example.test/TeamA/v1/").endpoint_url
  end

  test "a store created before its server was recorded falls back to the OpenAI endpoint" do
    Ai::Config.stubs(:current).returns(Ai::Config.new(endpoints: [ @endpoint ]))

    assert_equal BASE, VectorStore::Openai.for_store(nil).endpoint_url
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

  test "a file whose compensating deletion also fails keeps its id for the caller" do
    stub_json(:post, "/files", { id: "file-xyz" })
    stub_request(:post, "#{BASE}/vector_stores/vs_abc123/files").to_return(status: 500, body: "boom")
    stub_request(:delete, "#{BASE}/files/file-xyz").to_return(status: 500, body: "boom")

    response = @adapter.upload_file(store_id: "vs_abc123", file_content: "x", filename: "a.txt")

    assert_not response.success?
    assert_kind_of VectorStore::UploadCleanupError, response.error
    assert_equal "file-xyz", response.error.file_id
    assert_kind_of StandardError, response.error.attachment_error
    assert_kind_of StandardError, response.error.cleanup_error
  end

  test "file_status: ready, unreadable for an empty index, processing, or error" do
    { { status: "completed", usage_bytes: 2048 } => "ready", { status: "completed", usage_bytes: 0 } => "unreadable",
      { status: "in_progress" } => "processing", { status: "failed", last_error: { message: "bad file" } } => "error" }.each do |file, expected|
      WebMock.reset!
      stub_json(:get, "/vector_stores/vs_abc123/files/file-xyz", { id: "file-xyz", **file })

      assert_equal expected, @adapter.file_status(store_id: "vs_abc123", file_id: "file-xyz").data[:status]
    end
  end

  test "remove_file deletes the file through the Files API" do
    delete = stub_json(:delete, "/files/file-xyz", { deleted: true })

    assert @adapter.remove_file(store_id: "vs_abc123", file_id: "file-xyz").success?
    assert_requested delete
  end

  test "remove_file fails when the Files API deletion fails, so its row can't be dropped" do
    stub_request(:delete, "#{BASE}/files/file-xyz").to_return(status: 500, body: "boom")

    assert_not @adapter.remove_file(store_id: "vs_abc123", file_id: "file-xyz").success?
  end

  test "remove_file retries a Files API deletion that previously failed" do
    stub_request(:delete, "#{BASE}/files/file-xyz")
      .to_return({ status: 500, body: "boom" }, { status: 200, headers: JSON_HEADERS, body: { deleted: true }.to_json })

    assert_not @adapter.remove_file(store_id: "vs_abc123", file_id: "file-xyz").success?
    assert @adapter.remove_file(store_id: "vs_abc123", file_id: "file-xyz").success?
  end

  test "a file already gone from the Files API counts as removed" do
    stub_request(:delete, "#{BASE}/files/file-xyz").to_raise(Faraday::ResourceNotFound)

    assert @adapter.remove_file(store_id: "vs_abc123", file_id: "file-xyz").success?
  end

  test "delete_store leaves the store for a retry when a file can't be deleted" do
    stub_store_files
    stub_json(:delete, "/files/file-1", { deleted: true })
    stub_request(:delete, "#{BASE}/files/file-2").to_return(status: 500, body: "boom")
    store = stub_json(:delete, "/vector_stores/vs_abc123", { deleted: true })

    response = @adapter.delete_store(store_id: "vs_abc123")

    assert_not response.success?
    assert_includes response.error.message, "file-2"
    assert_not_requested store
  end

  test "delete_store can finish on a retry after a file deletion failed" do
    stub_store_files
    stub_json(:delete, "/files/file-1", { deleted: true })
    stub_request(:delete, "#{BASE}/files/file-2")
      .to_return({ status: 500, body: "boom" }, { status: 200, headers: JSON_HEADERS, body: { deleted: true }.to_json })
    store = stub_json(:delete, "/vector_stores/vs_abc123", { deleted: true })

    assert_not @adapter.delete_store(store_id: "vs_abc123").success?
    assert_not_requested store
    assert @adapter.delete_store(store_id: "vs_abc123").success?
    assert_requested store
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

  test "a long filename is shortened before its extension, which says what the file is" do
    long = "#{"a" * 250}.pdf"
    upload = stub_request(:post, "#{BASE}/files").with { _1.body.include?("filename=\"#{"a" * 196}.pdf\"") }
                                                  .to_return(status: 200, headers: JSON_HEADERS, body: { id: "file-xyz" }.to_json)
    stub_json(:post, "/vector_stores/vs_abc123/files", { id: "file-xyz", status: "in_progress" })

    assert @adapter.upload_file(store_id: "vs_abc123", file_content: "%PDF-1.4", filename: long).success?
    assert_requested upload
  end

  private
    def stub_json(method, path, body)
      stub_request(method, "#{BASE}#{path}").to_return(status: 200, headers: JSON_HEADERS, body: body.to_json)
    end

    def stub_store_files
      stub_request(:get, "#{BASE}/vector_stores/vs_abc123/files?limit=100")
        .to_return(status: 200, headers: JSON_HEADERS,
                   body: { data: [ { id: "file-1" }, { id: "file-2" } ], has_more: false }.to_json)
    end
end
