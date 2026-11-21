require "test_helper"

class VectorStore::EmbeddableTest < ActiveSupport::TestCase
  class EmbeddableHost
    include VectorStore::Embeddable
    # Expose private methods for testing
    public :extract_text, :chunk_text
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

  test "chunk_text hard-splits oversized paragraphs" do
    # A single paragraph longer than CHUNK_SIZE with no paragraph breaks
    long_para = "X" * 5000
    chunks = @host.chunk_text(long_para)

    assert chunks.size > 1
    chunks.each do |chunk|
      assert chunk.length <= VectorStore::Embeddable::CHUNK_SIZE + VectorStore::Embeddable::CHUNK_OVERLAP + 2,
        "Chunk too large: #{chunk.length} chars"
    end
  end
end
