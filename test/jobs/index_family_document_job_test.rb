require "test_helper"

class IndexFamilyDocumentJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @document = family_documents(:pending_doc)
    @document.file.attach(io: StringIO.new("a note"), filename: "notes.txt", content_type: "text/plain")
    @document.stubs(:family).returns(@family)
    use_ai_routes
  end

  test "sends the stored bytes to the store and purges after the ready write commits" do
    @family.expects(:index_document).with do |document, file_content:|
      assert_equal "a note", file_content
      document.update!(status: "ready", provider_file_id: "file-1")
      true
    end.returns(@document)
    DebugLogEntry.expects(:capture).never
    @document.file.expects(:purge).with do
      assert_equal "ready", @document.reload.status
      true
    end

    IndexFamilyDocumentJob.perform_now(@document)
  end

  test "keeps the upload attached while an asynchronous store is still indexing" do
    @family.expects(:index_document).with do |document, file_content:|
      assert_equal "a note", file_content
      document.update!(status: "processing", provider_file_id: "file-1")
      true
    end.returns(@document)
    @document.file.expects(:purge).never

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "processing", @document.reload.status
  end

  test "keeps the upload attached when the row has not settled" do
    @family.expects(:index_document).returns(@document)
    @document.file.expects(:purge).never

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "pending", @document.reload.status
    assert @document.file.attached?
  end

  test "a refused upload is marked as an error and logged before the file is purged" do
    @family.expects(:index_document).returns(nil)
    DebugLogEntry.expects(:capture).with do |args|
      args[:category] == "documents" && args[:source] == "IndexFamilyDocumentJob" && args[:family] == @family
    end
    @document.file.expects(:purge).with do
      assert_equal "error", @document.reload.status
      true
    end

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "error", @document.reload.status
    assert_equal "vector store refused the upload", @document.metadata["error"]
  end

  test "an indexing failure is marked, logged and purged after the error write commits" do
    @family.expects(:index_document).raises(StandardError, "store down")
    DebugLogEntry.expects(:capture).with do |args|
      args[:category] == "documents" && args[:message].include?("store down")
    end
    @document.file.expects(:purge).with do
      assert_equal "error", @document.reload.status
      true
    end

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "error", @document.reload.status
    assert_match(/store down/, @document.metadata["error"])
  end

  test "an error while recording a failure leaves the bytes attached for a retry" do
    @family.expects(:index_document).raises(StandardError, "store down")
    @document.stubs(:mark_error!).raises(ActiveRecord::RecordInvalid)
    @document.file.expects(:purge).never

    assert_raises(ActiveRecord::RecordInvalid) { IndexFamilyDocumentJob.perform_now(@document) }

    assert @document.file.attached?
  end

  test "sends nothing when embed is no longer available" do
    use_ai_routes(embed: [])
    @family.expects(:index_document).never
    @document.file.expects(:purge).never

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "pending", @document.reload.status
    assert @document.file.attached?
  end
end
