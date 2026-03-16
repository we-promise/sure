require "test_helper"

class VectorStore::PgvectorTest < ActiveSupport::TestCase
  setup do
    @adapter = VectorStore::Pgvector.new
  end

  test "create_store returns a UUID" do
    response = @adapter.create_store(name: "Test Store")
    assert response.success?
    assert_match(/\A[0-9a-f-]{36}\z/, response.data[:id])
  end

  test "delete_store executes delete query" do
    mock_conn = mock("connection")
    mock_conn.expects(:exec_delete).with(
      "DELETE FROM vector_store_chunks WHERE store_id = $1",
      "VectorStore::Pgvector DeleteStore",
      anything
    ).returns(0)

    @adapter.stubs(:connection).returns(mock_conn)

    response = @adapter.delete_store(store_id: "store-123")
    assert response.success?
  end

  test "upload_file extracts text, chunks, embeds, and inserts" do
    file_content = "Hello world"
    filename = "test.txt"
    store_id = "store-123"

    @adapter.expects(:extract_text).with(file_content, filename).returns("Hello world")
    @adapter.expects(:chunk_text).with("Hello world").returns([ "Hello world" ])
    @adapter.expects(:embed_batch).with([ "Hello world" ]).returns([ [ 0.1, 0.2, 0.3 ] ])

    mock_conn = mock("connection")
    mock_conn.expects(:exec_insert).once
    @adapter.stubs(:connection).returns(mock_conn)

    response = @adapter.upload_file(store_id: store_id, file_content: file_content, filename: filename)
    assert response.success?
    assert_match(/\A[0-9a-f-]{36}\z/, response.data[:file_id])
  end

  test "upload_file fails when text extraction returns nil" do
    @adapter.expects(:extract_text).returns(nil)

    response = @adapter.upload_file(store_id: "store-123", file_content: "\x00binary", filename: "photo.png")
    assert_not response.success?
    assert_match(/Could not extract text/, response.error.message)
  end

  test "upload_file fails when no chunks produced" do
    @adapter.expects(:extract_text).returns("some text")
    @adapter.expects(:chunk_text).returns([])

    response = @adapter.upload_file(store_id: "store-123", file_content: "some text", filename: "empty.txt")
    assert_not response.success?
    assert_match(/No chunks produced/, response.error.message)
  end

  test "upload_file inserts multiple chunks" do
    @adapter.expects(:extract_text).returns("chunk1\n\nchunk2")
    @adapter.expects(:chunk_text).returns([ "chunk1", "chunk2" ])
    @adapter.expects(:embed_batch).returns([ [ 0.1 ], [ 0.2 ] ])

    mock_conn = mock("connection")
    mock_conn.expects(:exec_insert).twice
    @adapter.stubs(:connection).returns(mock_conn)

    response = @adapter.upload_file(store_id: "store-123", file_content: "chunk1\n\nchunk2", filename: "doc.txt")
    assert response.success?
  end

  test "remove_file executes delete with store_id and file_id" do
    mock_conn = mock("connection")
    mock_conn.expects(:exec_delete).with(
      "DELETE FROM vector_store_chunks WHERE store_id = $1 AND file_id = $2",
      "VectorStore::Pgvector RemoveFile",
      anything
    ).returns(1)

    @adapter.stubs(:connection).returns(mock_conn)

    response = @adapter.remove_file(store_id: "store-123", file_id: "file-456")
    assert response.success?
  end

  test "search embeds query and returns scored results" do
    query_vector = [ 0.1, 0.2, 0.3 ]
    @adapter.expects(:embed).with("income").returns(query_vector)

    mock_result = [
      { "content" => "Total income: $85,000", "filename" => "tax_return.pdf", "file_id" => "file-xyz", "score" => 0.95 }
    ]

    mock_conn = mock("connection")
    mock_conn.expects(:exec_query).returns(mock_result)
    @adapter.stubs(:connection).returns(mock_conn)

    response = @adapter.search(store_id: "store-123", query: "income", max_results: 5)
    assert response.success?
    assert_equal 1, response.data.size
    assert_equal "Total income: $85,000", response.data.first[:content]
    assert_equal "tax_return.pdf", response.data.first[:filename]
    assert_equal 0.95, response.data.first[:score]
    assert_equal "file-xyz", response.data.first[:file_id]
  end

  test "search returns empty array when no results" do
    @adapter.expects(:embed).returns([ 0.1 ])

    mock_conn = mock("connection")
    mock_conn.expects(:exec_query).returns([])
    @adapter.stubs(:connection).returns(mock_conn)

    response = @adapter.search(store_id: "store-123", query: "nothing")
    assert response.success?
    assert_empty response.data
  end

  test "wraps errors in failure response" do
    @adapter.expects(:extract_text).raises(StandardError, "unexpected error")

    response = @adapter.upload_file(store_id: "store-123", file_content: "data", filename: "test.txt")
    assert_not response.success?
    assert_equal "unexpected error", response.error.message
  end

  test "supported_extensions returns the default list" do
    assert_includes @adapter.supported_extensions, ".pdf"
    assert_includes @adapter.supported_extensions, ".txt"
    assert_includes @adapter.supported_extensions, ".csv"
  end
end
