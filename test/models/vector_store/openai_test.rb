require "test_helper"

class VectorStore::OpenaiTest < ActiveSupport::TestCase
  setup do
    @adapter = VectorStore::Openai.new(access_token: "sk-test-key")
  end

  test "create_store wraps response" do
    mock_client = mock("openai_client")
    mock_vs = mock("vector_stores")
    mock_vs.expects(:create).with(parameters: { name: "Test Store" }).returns({ "id" => "vs_abc123" })
    mock_client.stubs(:vector_stores).returns(mock_vs)

    @adapter.instance_variable_set(:@client, mock_client)

    response = @adapter.create_store(name: "Test Store")
    assert response.success?
    assert_equal "vs_abc123", response.data[:id]
  end

  test "delete_store wraps response" do
    mock_client = mock("openai_client")
    mock_vs = mock("vector_stores")
    mock_vs.expects(:delete).with(id: "vs_abc123").returns(true)
    mock_client.stubs(:vector_stores).returns(mock_vs)

    @adapter.instance_variable_set(:@client, mock_client)

    response = @adapter.delete_store(store_id: "vs_abc123")
    assert response.success?
  end

  test "upload_file uploads and attaches to store" do
    mock_client = mock("openai_client")
    mock_files = mock("files")
    mock_files.expects(:upload).returns({ "id" => "file-xyz" })
    mock_vs_files = mock("vector_store_files")
    mock_vs_files.expects(:create).with(
      vector_store_id: "vs_abc123",
      parameters: { file_id: "file-xyz" }
    ).returns(true)

    mock_client.stubs(:files).returns(mock_files)
    mock_client.stubs(:vector_store_files).returns(mock_vs_files)

    @adapter.instance_variable_set(:@client, mock_client)

    response = @adapter.upload_file(
      store_id: "vs_abc123",
      file_content: "Hello world",
      filename: "test.txt"
    )

    assert response.success?
    assert_equal "file-xyz", response.data[:file_id]
  end

  test "remove_file deletes from store" do
    mock_client = mock("openai_client")
    mock_vs_files = mock("vector_store_files")
    mock_vs_files.expects(:delete).with(
      vector_store_id: "vs_abc123",
      id: "file-xyz"
    ).returns(true)
    mock_client.stubs(:vector_store_files).returns(mock_vs_files)

    @adapter.instance_variable_set(:@client, mock_client)

    response = @adapter.remove_file(store_id: "vs_abc123", file_id: "file-xyz")
    assert response.success?
  end

  test "search uses gem client and parses results" do
    mock_client = mock("openai_client")
    mock_vs = mock("vector_stores")
    mock_vs.expects(:search).with(
      id: "vs_abc123",
      parameters: { query: "income", max_num_results: 5 }
    ).returns({
      "data" => [
        {
          "file_id" => "file-xyz",
          "filename" => "tax_return.pdf",
          "score" => 0.95,
          "content" => [ { "type" => "text", "text" => "Total income: $85,000" } ]
        }
      ]
    })
    mock_client.stubs(:vector_stores).returns(mock_vs)

    @adapter.instance_variable_set(:@client, mock_client)

    response = @adapter.search(store_id: "vs_abc123", query: "income", max_results: 5)
    assert response.success?
    assert_equal 1, response.data.size
    assert_equal "Total income: $85,000", response.data.first[:content]
    assert_equal "tax_return.pdf", response.data.first[:filename]
    assert_equal 0.95, response.data.first[:score]
  end

  test "search returns empty array when no results" do
    mock_client = mock("openai_client")
    mock_vs = mock("vector_stores")
    mock_vs.expects(:search).returns({ "data" => [] })
    mock_client.stubs(:vector_stores).returns(mock_vs)

    @adapter.instance_variable_set(:@client, mock_client)

    response = @adapter.search(store_id: "vs_abc123", query: "nothing")
    assert response.success?
    assert_empty response.data
  end

  test "wraps errors in failure response" do
    mock_client = mock("openai_client")
    mock_vs = mock("vector_stores")
    mock_vs.expects(:create).raises(StandardError, "API error")
    mock_client.stubs(:vector_stores).returns(mock_vs)

    @adapter.instance_variable_set(:@client, mock_client)

    response = @adapter.create_store(name: "Broken Store")
    assert_not response.success?
    assert_equal "API error", response.error.message
  end

  test "supported_extensions returns the default list" do
    assert_includes @adapter.supported_extensions, ".pdf"
    assert_includes @adapter.supported_extensions, ".docx"
    assert_includes @adapter.supported_extensions, ".csv"
  end
end
