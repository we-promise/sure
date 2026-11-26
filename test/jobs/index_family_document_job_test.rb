require "test_helper"

class IndexFamilyDocumentJobTest < ActiveJob::TestCase
  setup do
    @document = family_documents(:pending_doc)
    @family = @document.family
    @document.file.attach(io: StringIO.new("a note"), filename: "notes.txt", content_type: "text/plain")
    use_ai_routes
  end

  test "sends the stored bytes and purges once the status is settled" do
    @family.expects(:index_document).with do |document, file_content:|
      assert_equal "a note", file_content
      document.update!(status: "ready", provider_file_id: "file-1")
      true
    end.returns(@document)
    @document.file.expects(:purge).with do
      assert_equal "ready", @document.reload.status
      true
    end

    IndexFamilyDocumentJob.perform_now(@document)
  end

  test "keeps the upload while the store is still indexing" do
    @family.expects(:index_document).with do |document, file_content:|
      document.update!(status: "processing", provider_file_id: "file-1")
      true
    end.returns(@document)

    IndexFamilyDocumentJob.perform_now(@document)

    assert @document.reload.file.attached?
  end

  test "a refused upload is recorded, logged and purged" do
    @family.expects(:index_document).returns(nil)
    DebugLogEntry.expects(:capture).with do |args|
      args[:category] == "documents" && args[:source] == "IndexFamilyDocumentJob" && args[:family] == @family
    end
    @document.file.expects(:purge)

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "error", @document.reload.status
    assert_equal "vector store refused the upload", @document.metadata["error"]
  end

  test "an indexing error is recorded and purged" do
    @family.expects(:index_document).raises(StandardError, "store down")
    @document.file.expects(:purge).with do
      assert_equal "error", @document.reload.status
      true
    end

    IndexFamilyDocumentJob.perform_now(@document)

    assert_match(/store down/, @document.reload.metadata["error"])
  end

  test "an error while recording a failure leaves the bytes attached" do
    @family.expects(:index_document).raises(StandardError, "store down")
    @document.stubs(:mark_error!).raises(ActiveRecord::RecordInvalid)
    @document.file.expects(:purge).never

    assert_raises(ActiveRecord::RecordInvalid) { IndexFamilyDocumentJob.perform_now(@document) }

    assert @document.file.attached?
  end

  test "a busy host leaves the upload for its retry" do
    @family.expects(:index_document).raises(Ai::Error::Busy, "busy")

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "pending", @document.reload.status
    assert @document.file.attached?
  end

  test "does nothing when embed is no longer available" do
    use_ai_routes(embed: [])
    @family.expects(:index_document).never

    IndexFamilyDocumentJob.perform_now(@document)

    assert @document.file.attached?
  end
end
