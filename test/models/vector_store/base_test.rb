require "test_helper"

class VectorStore::BaseTest < ActiveSupport::TestCase
  setup do
    @adapter = VectorStore::Base.new
  end

  test "create_store raises NotImplementedError" do
    assert_raises(NotImplementedError) { @adapter.create_store(name: "test") }
  end

  test "delete_store raises NotImplementedError" do
    assert_raises(NotImplementedError) { @adapter.delete_store(store_id: "test") }
  end

  test "upload_file raises NotImplementedError" do
    assert_raises(NotImplementedError) { @adapter.upload_file(store_id: "s", file_content: "c", filename: "f") }
  end

  test "remove_file raises NotImplementedError" do
    assert_raises(NotImplementedError) { @adapter.remove_file(store_id: "s", file_id: "f") }
  end

  test "search raises NotImplementedError" do
    assert_raises(NotImplementedError) { @adapter.search(store_id: "s", query: "q") }
  end

  test "supported_extensions includes common file types" do
    exts = @adapter.supported_extensions
    assert_includes exts, ".pdf"
    assert_includes exts, ".docx"
    assert_includes exts, ".xlsx"
    assert_includes exts, ".csv"
    assert_includes exts, ".json"
    assert_includes exts, ".txt"
    assert_includes exts, ".md"
  end

  test "SUPPORTED_EXTENSIONS is frozen" do
    assert VectorStore::Base::SUPPORTED_EXTENSIONS.frozen?
  end
end
