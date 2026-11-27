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

  test "a redelivered job does not re-index a settled document" do
    @document.update!(status: "ready", provider_file_id: "file-1")
    @family.expects(:index_document).never
    @document.file.expects(:purge)

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "ready", @document.reload.status
  end

  test "a job accepted before the enqueue raised leaves its bytes for recovery" do
    @document.update!(status: "error", metadata: { "enqueue_error" => "Redis::CannotConnectError" })
    @family.expects(:index_document).never
    @document.file.expects(:purge).never

    IndexFamilyDocumentJob.perform_now(@document)

    assert @document.reload.file.attached?
    assert_equal "Redis::CannotConnectError", @document.metadata["enqueue_error"]
  end

  test "the retry clears the recovery marker once it starts indexing" do
    @document.update!(metadata: { "enqueue_error" => "Redis::CannotConnectError", "error" => "enqueue failed" })
    @family.expects(:index_document).with do |document, file_content:|
      assert_nil document.metadata["enqueue_error"]
      assert_equal "a note", file_content
      true
    end.returns(@document)

    IndexFamilyDocumentJob.perform_now(@document)

    assert_nil @document.reload.metadata["enqueue_error"]
    assert_not @document.metadata.key?("error")
  end

  test "indexes inside a call context carrying the document id" do
    correlation_ids = []
    @family.expects(:index_document).with do |document, file_content:|
      correlation_ids << Ai::CallContext.correlation_id
      true
    end.returns(@document)

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal [ "family_document:#{@document.id}" ], correlation_ids
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

  test "a failed purge does not overwrite the indexing result" do
    @family.expects(:index_document).with do |document, file_content:|
      document.update!(status: "ready", provider_file_id: "file-1")
      true
    end.returns(@document)
    @document.file.expects(:purge).raises(StandardError, "storage down")
    Rails.logger.expects(:warn).with(regexp_matches(/couldn't purge the file for document #{@document.id}/))
    DebugLogEntry.expects(:capture).with do |args|
      args[:level] == "warn" && args[:message].include?("purge") && args[:family] == @family
    end

    assert_nothing_raised { IndexFamilyDocumentJob.perform_now(@document) }

    assert_equal "ready", @document.reload.status
    assert_nil @document.metadata["error"]
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

  test "embed no longer available marks the upload failed and purges it" do
    use_ai_routes(embed: [])
    @family.expects(:index_document).never
    DebugLogEntry.expects(:capture).with do |args|
      args[:message].include?("embeddings are no longer available") && args[:family] == @family
    end
    @document.file.expects(:purge).with do
      assert_equal "error", @document.reload.status
      true
    end

    IndexFamilyDocumentJob.perform_now(@document)

    assert_equal "error", @document.reload.status
    assert_match(/embeddings are no longer available/, @document.metadata["error"])
  end
end
