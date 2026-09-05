require "test_helper"

class AccountStatement::VectorStoreBridgeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
  end

  def build_statement(filename: "releve.pdf", account: nil)
    statement = @family.account_statements.build(
      account: account,
      filename: filename,
      content_type: "application/pdf",
      byte_size: 42,
      checksum: SecureRandom.hex(16),
      content_sha256: SecureRandom.hex(32),
      source: :manual_upload,
      upload_status: :stored,
      review_status: :unmatched,
      currency: "USD"
    )
    statement.original_file.attach(io: StringIO.new("%PDF-1.4 fake"), filename: filename, content_type: "application/pdf")
    statement
  end

  def stub_upload(file_id)
    VectorStore::Registry.stubs(:adapter).returns(
      stub(
        upload_file: VectorStore::Response.new(success?: true, data: { file_id: file_id }, error: nil)
      )
    )
    @family.update!(vector_store_id: "vs_test")
  end

  test "creating a statement enqueues its indexing" do
    statement = build_statement

    assert_enqueued_with(job: IndexAccountStatementJob) do
      statement.save!
    end
  end

  test "indexing pushes the file into the document store with a linking key" do
    statement = build_statement
    statement.save!

    # Expected on the class, not on statement.family: index_in_vector_store!
    # locks the row, and the reload that comes with the lock resets the cached
    # association, so an expectation set on this instance would never be met.
    Family.any_instance.expects(:upload_document).with do |args|
      args[:filename] == "releve.pdf" &&
        args[:metadata]["account_statement_id"] == statement.id &&
        args[:metadata]["type"] == "account_statement"
    end.returns(FamilyDocument.new)

    assert statement.index_in_vector_store!
  end

  test "does not index the same statement twice" do
    statement = build_statement
    statement.save!

    @family.family_documents.create!(
      filename: "releve.pdf",
      content_type: "application/pdf",
      file_size: 42,
      provider_file_id: "file_1",
      status: "ready",
      metadata: { "account_statement_id" => statement.id }
    )

    assert statement.indexed_in_vector_store?
    assert_not statement.index_in_vector_store!, "a second index would duplicate the document"
  end

  # The existence check alone is check-then-write, and ProcessPdfJob runs the
  # same check on a different queue with no ordering between them: two workers
  # that both read "not indexed" both upload, leaving two documents for one
  # statement. Only the row lock serializes them, so its absence is the bug.
  # A real race cannot be reproduced in-process, so what is pinned is that the
  # lock is taken before the check.
  test "takes the statement row lock before deciding to index" do
    statement = build_statement
    statement.save!

    statement.expects(:with_lock).once

    statement.index_in_vector_store!
  end

  # The account link decides who may read the document back, so it lives in a
  # column rather than a jsonb key: metadata cannot be joined, indexed or
  # constrained, and the store itself is one family-wide index.
  test "an indexed statement lands with its owning account on the document" do
    account = accounts(:connected)
    statement = build_statement(account: account)
    statement.review_status = :linked
    statement.save!

    stub_upload("file_acct")

    statement.index_in_vector_store!
    document = @family.family_documents.find_by(provider_file_id: "file_acct")

    assert_equal account.id, document.account_id
    assert_includes @family.family_documents.readable_by(users(:family_admin)), document
    assert_not_includes @family.family_documents.readable_by(users(:family_member)), document
  end

  # Indexing runs on upload, which is often before anyone has said which account
  # the statement belongs to. The document therefore starts family-wide and only
  # the link narrows it, so the link has to reach the document too.
  test "linking a statement narrows its indexed document to the account" do
    statement = build_statement
    statement.save!

    stub_upload("file_link")
    statement.index_in_vector_store!
    document = @family.family_documents.find_by(provider_file_id: "file_link")

    assert_nil document.account_id
    assert_includes @family.family_documents.readable_by(users(:family_member)), document

    statement.link_to_account!(accounts(:connected))

    assert_equal accounts(:connected).id, document.reload.account_id
    assert_equal accounts(:connected).id, document.metadata["account_id"]
    assert_not_includes @family.family_documents.readable_by(users(:family_member)), document
  end

  test "unlinking a statement releases its indexed document from the account" do
    statement = build_statement(account: accounts(:connected))
    statement.review_status = :linked
    statement.save!

    stub_upload("file_unlink")
    statement.index_in_vector_store!
    document = @family.family_documents.find_by(provider_file_id: "file_unlink")

    assert_equal accounts(:connected).id, document.account_id

    AccountStatement::AccountMatcher.any_instance.stubs(:best_match).returns(nil)
    statement.unlink!

    assert_nil document.reload.account_id
    assert_not document.metadata.key?("account_id"), "a released document must not keep the account it left"
    assert_includes @family.family_documents.readable_by(users(:family_member)), document
  end

  test "an install with no vector store still accepts the upload" do
    statement = build_statement

    assert_nothing_raised { statement.save! }
    assert statement.persisted?
    assert_not statement.index_in_vector_store!, "no adapter means no indexing, not a failed upload"
  end

  test "the job never lets an indexing failure escape" do
    statement = build_statement
    statement.save!

    AccountStatement.any_instance.stubs(:index_in_vector_store!).raises(StandardError, "boom")

    assert_nothing_raised { IndexAccountStatementJob.new.perform(statement.id) }
  end

  test "the job tolerates a statement deleted before it runs" do
    assert_nothing_raised { IndexAccountStatementJob.new.perform(SecureRandom.uuid) }
  end
end
