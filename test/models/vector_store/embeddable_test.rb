require "test_helper"

class VectorStore::EmbeddableTest < ActiveSupport::TestCase
  class EmbeddableHost
    include VectorStore::Embeddable
    # Expose private methods for testing
    public :extract_text, :chunk_text, :embed, :embed_batch
  end

  setup do
    @host = EmbeddableHost.new
  end

  # --- extract_text ---

  test "extract_text returns plain text for .txt files" do
    result = @host.extract_text("Hello world", "notes.txt")
    assert_equal "Hello world", result
  end

  test "extract_text returns content for markdown files" do
    result = @host.extract_text("# Heading\n\nBody", "readme.md")
    assert_equal "# Heading\n\nBody", result
  end

  test "extract_text returns content for code files" do
    result = @host.extract_text("def foo; end", "app.rb")
    assert_equal "def foo; end", result
  end

  test "extract_text returns nil for unsupported binary formats" do
    assert_nil @host.extract_text("\x00\x01binary", "photo.png")
    assert_nil @host.extract_text("\x00\x01binary", "archive.zip")
  end

  test "extract_text handles PDF files" do
    pdf_content = "fake pdf bytes"
    mock_page = mock("page")
    mock_page.stubs(:text).returns("Page 1 content")

    mock_reader = mock("reader")
    mock_reader.stubs(:pages).returns([ mock_page ])

    PDF::Reader.expects(:new).with(instance_of(StringIO)).returns(mock_reader)

    result = @host.extract_text(pdf_content, "document.pdf")
    assert_equal "Page 1 content", result
  end

  test "extract_text returns nil when PDF extraction fails" do
    PDF::Reader.expects(:new).raises(StandardError, "corrupt pdf")

    result = @host.extract_text("bad data", "broken.pdf")
    assert_nil result
  end

  # --- chunk_text ---

  test "chunk_text returns empty array for blank text" do
    assert_equal [], @host.chunk_text("")
    assert_equal [], @host.chunk_text(nil)
  end

  test "chunk_text returns single chunk for short text" do
    text = "Short paragraph."
    chunks = @host.chunk_text(text)
    assert_equal 1, chunks.size
    assert_equal "Short paragraph.", chunks.first
  end

  test "chunk_text splits on paragraph boundaries" do
    # Create text that exceeds CHUNK_SIZE when combined
    para1 = "A" * 1200
    para2 = "B" * 1200
    text = "#{para1}\n\n#{para2}"

    chunks = @host.chunk_text(text)
    assert_equal 2, chunks.size
    assert_includes chunks.first, "A" * 1200
    assert_includes chunks.last, "B" * 1200
  end

  test "chunk_text includes overlap between chunks" do
    para1 = "A" * 1500
    para2 = "B" * 1500
    text = "#{para1}\n\n#{para2}"

    chunks = @host.chunk_text(text)
    assert_equal 2, chunks.size
    # Second chunk should start with overlap from end of first chunk
    overlap = para1.last(VectorStore::Embeddable::CHUNK_OVERLAP)
    assert chunks.last.start_with?(overlap)
  end

  test "chunk_text keeps small paragraphs together" do
    paragraphs = Array.new(5) { |i| "Paragraph #{i} content." }
    text = paragraphs.join("\n\n")

    chunks = @host.chunk_text(text)
    assert_equal 1, chunks.size
  end

  # --- embed ---

  test "embed calls embedding endpoint and returns vector" do
    expected_vector = [ 0.1, 0.2, 0.3 ]
    stub_response = { "data" => [ { "embedding" => expected_vector, "index" => 0 } ] }

    mock_client = mock("faraday")
    mock_client.expects(:post).with("embeddings").yields(mock_request).returns(
      OpenStruct.new(body: stub_response)
    )
    @host.instance_variable_set(:@embedding_client, mock_client)

    result = @host.embed("test text")
    assert_equal expected_vector, result
  end

  test "embed raises on failed response" do
    mock_client = mock("faraday")
    mock_client.expects(:post).with("embeddings").yields(mock_request).returns(
      OpenStruct.new(body: { "error" => "bad request" })
    )
    @host.instance_variable_set(:@embedding_client, mock_client)

    assert_raises(VectorStore::Error) { @host.embed("test text") }
  end

  # --- embed_batch ---

  test "embed_batch processes texts and returns ordered vectors" do
    texts = [ "first", "second", "third" ]
    vectors = [ [ 0.1 ], [ 0.2 ], [ 0.3 ] ]
    stub_response = {
      "data" => [
        { "embedding" => vectors[0], "index" => 0 },
        { "embedding" => vectors[1], "index" => 1 },
        { "embedding" => vectors[2], "index" => 2 }
      ]
    }

    mock_client = mock("faraday")
    mock_client.expects(:post).with("embeddings").yields(mock_request).returns(
      OpenStruct.new(body: stub_response)
    )
    @host.instance_variable_set(:@embedding_client, mock_client)

    result = @host.embed_batch(texts)
    assert_equal vectors, result
  end

  test "embed_batch handles multiple batches" do
    # Override batch size constant for testing
    original = VectorStore::Embeddable::EMBED_BATCH_SIZE
    VectorStore::Embeddable.send(:remove_const, :EMBED_BATCH_SIZE)
    VectorStore::Embeddable.const_set(:EMBED_BATCH_SIZE, 2)

    texts = [ "a", "b", "c" ]

    batch1_response = {
      "data" => [
        { "embedding" => [ 0.1 ], "index" => 0 },
        { "embedding" => [ 0.2 ], "index" => 1 }
      ]
    }
    batch2_response = {
      "data" => [
        { "embedding" => [ 0.3 ], "index" => 0 }
      ]
    }

    mock_client = mock("faraday")
    mock_client.expects(:post).with("embeddings").twice
      .yields(mock_request)
      .returns(OpenStruct.new(body: batch1_response))
      .then.returns(OpenStruct.new(body: batch2_response))
    @host.instance_variable_set(:@embedding_client, mock_client)

    result = @host.embed_batch(texts)
    assert_equal [ [ 0.1 ], [ 0.2 ], [ 0.3 ] ], result
  ensure
    VectorStore::Embeddable.send(:remove_const, :EMBED_BATCH_SIZE)
    VectorStore::Embeddable.const_set(:EMBED_BATCH_SIZE, original)
  end

  private

    def mock_request
      request = OpenStruct.new(body: nil)
      request
    end
end
