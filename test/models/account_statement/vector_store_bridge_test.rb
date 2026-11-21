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

  # Indexing is an `embed` call: queued only when embed is available for the uploader and the
  # uploader's own AI switch is on.
  def upload_as(ai_enabled:, embed: true)
    user = users(:family_admin)
    user.stubs(:ai_enabled?).returns(ai_enabled)
    Current.stubs(:user).returns(user)
    embed ? use_ai_routes : use_ai_routes(embed: [])
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

  # The indexed copy is a separate row and a provider-side file, so deleting the
  # statement left its text searchable by everyone the document was readable by.
  test "deleting a statement removes its indexed copy" do
    statement = build_statement
    statement.save!

    stub_upload("file_destroy")
    statement.index_in_vector_store!
    document = @family.family_documents.find_by(provider_file_id: "file_destroy")

    assert_not_nil document

    Family.any_instance.expects(:remove_document).with(document).once

    statement.destroy!
  end

  # add_reference ... foreign_key: true defaults to NO ACTION, so destroying an
  # account that had an indexed statement raised InvalidForeignKey and rolled the
  # whole destroy back. The link is nullable: losing the account makes the
  # document family-wide again, which is what the column already means.
  test "destroying an account releases its documents instead of blocking" do
    account = @family.accounts.create!(
      accountable: Depository.new, name: "Compte a supprimer", balance: 10, currency: "USD"
    )
    document = @family.family_documents.create!(
      filename: "releve.pdf", content_type: "application/pdf", file_size: 42,
      provider_file_id: "file_fk", status: "ready", account: account
    )

    assert_nothing_raised { account.destroy! }
    assert_nil document.reload.account_id
  end

  # An unlinked statement is gated on statement_manager? by
  # AccountStatement#viewable_by?, so "no account" must not read as "everyone":
  # a guest reaching the vault through search would otherwise get its text.
  test "an unmatched statement's document stays out of a guest's reach" do
    statement = build_statement
    statement.save!

    stub_upload("file_guest")
    statement.index_in_vector_store!
    document = @family.family_documents.find_by(provider_file_id: "file_guest")

    guest = users(:family_member)
    guest.update!(role: :guest)

    assert_nil document.account_id
    assert_not_includes @family.family_documents.readable_by(guest), document
    assert_includes @family.family_documents.readable_by(users(:family_admin)), document
  end

  # readable_by evaluates the account's own sharing, so a document pointed at
  # another family's account would be judged against the wrong owner entirely.
  test "a document cannot name an account from another family" do
    foreign_account = Account.create!(
      family: families(:empty),
      owner: users(:empty),
      name: "Another family's account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    document = @family.family_documents.new(
      filename: "etranger.pdf",
      content_type: "application/pdf",
      status: "ready",
      account: foreign_account
    )

    assert_not document.valid?
    assert_includes document.errors.attribute_names, :account
  end

  # index_in_vector_store! answers false for "nothing attached" too, so the
  # refusal log reported a missing file as a provider saying no.
  test "does not report a missing attachment as a provider refusal" do
    statement = build_statement
    statement.save!
    statement.original_file.purge

    stub_upload("file_never_used")

    DebugLogEntry.expects(:capture).never

    IndexAccountStatementJob.new.perform(statement.id)
  end

  test "a legacy job without an uploader does not index once AI is off for the family" do
    statement = build_statement
    statement.save!
    use_ai_routes
    User.any_instance.stubs(:ai_enabled?).returns(false)
    Family.any_instance.expects(:upload_document).never

    IndexAccountStatementJob.perform_now(statement.id)

    assert_not statement.indexed_in_vector_store?, "a skipped upload must leave the row visibly non-indexed"
  end

  test "the job re-checks the uploader's switch before it uploads" do
    statement = build_statement
    statement.save!
    uploader = users(:family_admin)
    uploader.update!(ai_enabled: false)
    use_ai_routes
    Family.any_instance.expects(:upload_document).never

    IndexAccountStatementJob.perform_now(statement.id, uploader.id)

    assert_not statement.indexed_in_vector_store?
  end

  test "a legacy job with an opted-in uploader reaches the upload" do
    statement = build_statement
    statement.save!
    uploader = users(:family_admin)
    uploader.update!(ai_enabled: true)
    use_ai_routes
    Family.any_instance.expects(:upload_document).once.returns(FamilyDocument.new)

    IndexAccountStatementJob.perform_now(statement.id, uploader.id)
  end
end
