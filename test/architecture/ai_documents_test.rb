require "test_helper"

# A vault upload is indexed only when `embed` is available for its uploader and the uploader's
# own AI switch is on; the indexing job re-checks the route; a search returns only documents the
# asking user may read; and search_family_files is always listed, falling back to the vault's
# metadata with the router's reason.
class AiDocumentsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  test "a vault upload is indexed only with embed available and the uploader's switch on" do
    [ [ true, true, 1 ], [ false, true, 0 ], [ true, false, 0 ] ].each do |switch, embed, expected|
      clear_enqueued_jobs
      @user.stubs(:ai_enabled?).returns(switch)
      Current.stubs(:user).returns(@user)
      embed ? use_ai_routes : use_ai_routes(embed: [])

      statement(@family).save!

      assert_equal expected, enqueued_jobs.count { _1["job_class"] == "IndexAccountStatementJob" }, "switch #{switch}, embed #{embed}"
    end
  end

  test "the indexing job runs on embed's lane and re-checks the route" do
    use_ai_routes(embed: [])
    record = statement(@family).tap(&:save!)
    @family.expects(:upload_document).never
    AccountStatement.any_instance.expects(:index_in_vector_store!).never

    IndexAccountStatementJob.perform_now(record.id)

    assert_equal Ai::Routes.queue_for(:embed), IndexAccountStatementJob.new.queue_name
  end

  test "a search returns only documents the asking user may read" do
    guest = users(:family_member)
    AccountStatement.stubs(:statement_manager?).with(@user).returns(true)
    AccountStatement.stubs(:statement_manager?).with(guest).returns(false)   # as a guest is
    readable = @family.family_documents.create!(filename: "tax.pdf", provider_file_id: "file-tax", status: "ready")
    unlinked = @family.family_documents.create!(filename: "stmt.pdf", provider_file_id: "file-stmt", status: "ready",
                                                metadata: { "account_statement_id" => SecureRandom.uuid })
    results = [ { file_id: readable.provider_file_id, content: "a" }, { file_id: unlinked.provider_file_id, content: "b" } ]

    assert_equal %w[file-tax file-stmt], @family.readable_documents(results, @user).map { _1[:file_id] }
    assert_equal %w[file-tax], @family.readable_documents(results, guest).map { _1[:file_id] }
  end

  test "search_family_files is always listed, and without AI falls back with the router's reason" do
    use_no_ai

    assert_includes Assistant.function_classes(@user), Assistant::Function::SearchFamilyFiles
    result = Assistant::Function::SearchFamilyFiles.new(@user).call("query" => "statement")
    assert_equal "metadata_only", result[:search_mode]
    assert_equal "not_configured", result[:reason]
  end

  test "a search embeds its query under search_documents, on embed's model" do
    use_ai_routes
    requests = stub_ai
    VectorStore::Pgvector.any_instance.stubs(:ensure_schema!)
    VectorStore::Pgvector.any_instance.stubs(:connection).returns(stub(exec_query: [], select_value: nil))
    VectorStore::Registry.stubs(:adapter).returns(VectorStore::Pgvector.new)
    @family.update!(vector_store_id: "store-1")

    @family.search_documents("rent", user: @user)

    assert_equal [ :search_documents ], requests.map(&:feature)
    assert_equal [ "nomic-embed-text" ], requests.map { _1.model.name }
  end

  test "a search hit with no family_documents row is withheld, with or without an asking user" do
    tracked = @family.family_documents.create!(filename: "tax.pdf", provider_file_id: "file-tax", status: "ready")
    results = [ { file_id: tracked.provider_file_id, content: "a" }, { file_id: "file-lost", content: "an untracked statement" } ]

    assert_equal %w[file-tax], @family.readable_documents(results, @user).map { _1[:file_id] }
    assert_equal %w[file-tax], @family.tracked_documents(results).map { _1[:file_id] }
  end

  test "an uploaded file whose row can't be written is removed from the store again" do
    adapter = mock("adapter")
    adapter.expects(:upload_file).returns(VectorStore::Response.new(success?: true, data: { file_id: "file-1" }, error: nil))
    adapter.expects(:remove_file).with(store_id: "vs-1", file_id: "file-1")
    @family.stubs(:vector_store_adapter).returns(adapter)
    @family.stubs(:ensure_vector_store!).returns("vs-1")
    @family.family_documents.stubs(:create!).raises(ActiveRecord::RecordInvalid)

    assert_raises(ActiveRecord::RecordInvalid) { @family.upload_document(file_content: "x", filename: "s.pdf") }
  end

  test "the indexing job sends nothing once the uploader has turned AI off" do
    use_ai_routes
    record = statement(@family).tap(&:save!)
    @user.update!(ai_enabled: false)
    AccountStatement.any_instance.expects(:index_in_vector_store!).never

    IndexAccountStatementJob.perform_now(record.id, @user.id)
  end

  test "a copy already uploaded but still processing is polled again instead of uploaded twice" do
    record = statement(@family).tap(&:save!)
    copy = @family.family_documents.create!(filename: "s.pdf", provider_file_id: "file-s", status: "ready",
                                            metadata: { "account_statement_id" => record.id })
    copy.update_column(:status, "processing")
    @family.expects(:upload_document).never

    assert_enqueued_with(job: VectorStore::IndexStatusJob) { assert_not record.index_in_vector_store! }
  end

  test "the family's store goes only when its deletion commits" do
    family = Family.create!(name: "Leaving", vector_store_id: "vs-gone")
    adapter = mock("adapter")
    Family.any_instance.stubs(:vector_store_adapter).returns(adapter)

    adapter.expects(:delete_store).never
    Family.transaction do
      family.destroy!
      raise ActiveRecord::Rollback
    end

    adapter.expects(:delete_store).with(store_id: "vs-gone").returns(VectorStore::Response.new(success?: true, data: nil, error: nil))
    family.reload.destroy!
  end

  private
    def statement(family)
      family.account_statements.build(filename: "releve-#{SecureRandom.hex(4)}.pdf", content_type: "application/pdf", byte_size: 42,
                                      checksum: SecureRandom.hex(16), content_sha256: SecureRandom.hex(32), source: :manual_upload,
                                      upload_status: :stored, review_status: :unmatched, currency: "USD").tap do
        _1.original_file.attach(io: StringIO.new("%PDF-1.4 fake"), filename: "releve.pdf", content_type: "application/pdf")
      end
    end
end
