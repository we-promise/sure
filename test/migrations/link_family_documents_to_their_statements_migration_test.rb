require "test_helper"
require Rails.root.join("db/migrate/20261123220100_link_family_documents_to_their_statements")
require Rails.root.join("db/migrate/20261124120000_move_family_document_statement_links_into_metadata")

# Main's link (#5701), then the AI plumbing's move of that link into metadata. The test schema has
# no account_statement_id column, so each test runs the move's `down` to get it back.
class LinkFamilyDocumentsToTheirStatementsMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    migrate(MoveFamilyDocumentStatementLinksIntoMetadata, :down)
  end

  teardown do
    FamilyDocument.reset_column_information
    ActiveRecord::Base.connection.clear_cache!
  end

  test "links a processed PDF to the statement with its filename and size" do
    statement = create_statement("march.pdf", "%PDF-1.4 March")
    document = processed_document("march.pdf", statement.original_file.byte_size)

    run_migration

    assert_linked statement, document
  end

  test "leaves a processed PDF unlinked when it predates the statement's import" do
    document = processed_document("march.pdf", "%PDF-1.4 March".bytesize, created_at: 1.year.ago)
    statement = create_statement("march.pdf", "%PDF-1.4 March")

    run_migration

    assert_equal statement.original_file.byte_size, document.file_size
    assert_not_linked document
  end

  test "leaves a processed PDF unlinked when its statement was never imported" do
    statement = AccountStatement.create_from_upload!(family: @family, account: accounts(:connected), file: pdf_upload("march.pdf", "%PDF-1.4 March"))
    document = processed_document("march.pdf", statement.original_file.byte_size)

    run_migration

    assert_not_linked document
  end

  test "leaves a processed PDF unlinked when no statement has its size" do
    create_statement("march.pdf", "%PDF-1.4 March")
    document = processed_document("march.pdf", 1)

    run_migration

    assert_not_linked document
  end

  test "leaves a processed PDF unlinked when two statements could be its own" do
    first = create_statement("march.pdf", "%PDF-1.4 March A")
    create_statement("march.pdf", "%PDF-1.4 March B")
    document = processed_document("march.pdf", first.original_file.byte_size)

    run_migration

    assert_not_linked document
  end

  test "leaves files uploaded straight to the store alone" do
    statement = create_statement("notes.pdf", "%PDF-1.4 Notes")
    document = @family.family_documents.create!(filename: "notes.pdf", file_size: statement.original_file.byte_size,
                                                provider_file_id: "file-direct", status: "ready", metadata: {})

    run_migration

    assert_not_linked document
  end

  test "does not link a statement of another family" do
    statement = AccountStatement.create_from_upload!(family: families(:empty), account: nil, file: pdf_upload("march.pdf", "%PDF-1.4 March"))
    PdfImport.create_from_statement!(statement: statement)
    document = processed_document("march.pdf", statement.original_file.byte_size)

    run_migration

    assert_not_linked document
  end

  test "logs each family's processed PDFs that stay hidden, once, and not the linked ones" do
    statement = create_statement("march.pdf", "%PDF-1.4 March")
    processed_document("march.pdf", statement.original_file.byte_size)
    hidden = [ processed_document("old-1.pdf", 1), processed_document("old-2.pdf", 2) ]

    assert_difference -> { DebugLogEntry.where(category: "documents", family_id: @family.id).count }, 1 do
      run_migration
    end

    entry = DebugLogEntry.where(category: "documents", family_id: @family.id).sole
    assert_equal "warn", entry.level
    assert_equal 2, entry.metadata["count"]
    assert_equal hidden.map(&:id).sort, entry.metadata["family_document_ids"].sort
    assert_equal %w[old-1.pdf old-2.pdf], entry.metadata["filenames"].sort
  end

  test "keeps a link already in metadata" do
    statement = create_statement("march.pdf", "%PDF-1.4 March")
    document = @family.family_documents.create!(filename: "march.pdf", file_size: statement.original_file.byte_size,
                                                provider_file_id: "file-copy", status: "ready",
                                                metadata: { "type" => "account_statement", "account_statement_id" => statement.id })

    run_migration

    assert_equal({ "type" => "account_statement", "account_statement_id" => statement.id }, document.reload.metadata)
  end

  private
    def run_migration
      migrate(LinkFamilyDocumentsToTheirStatements, :up)
      migrate(MoveFamilyDocumentStatementLinksIntoMetadata, :up)
    end

    # The column comes and goes inside the test's transaction: Postgres can't reuse a statement
    # prepared against the other shape.
    def migrate(migration, direction)
      ActiveRecord::Migration.suppress_messages { migration.new.public_send(direction) }
      FamilyDocument.reset_column_information
      ActiveRecord::Base.connection.clear_cache!
    end

    def assert_linked(statement, document)
      document.reload
      assert_equal statement.id, document.metadata["account_statement_id"]
      assert_equal statement.account_id, document.account_id
    end

    def assert_not_linked(document)
      document.reload
      assert_nil document.metadata["account_statement_id"]
      assert_nil document.account_id
    end

    # A statement ProcessPdfJob worked on: it has a PdfImport.
    def create_statement(filename, content)
      AccountStatement.create_from_upload!(family: @family, account: accounts(:connected), file: pdf_upload(filename, content)).tap do |statement|
        PdfImport.create_from_statement!(statement: statement)
      end
    end

    def pdf_upload(filename, content)
      uploaded_file(filename: filename, content_type: "application/pdf", content: content)
    end

    def processed_document(filename, file_size, created_at: Time.current)
      @family.family_documents.create!(filename: filename, file_size: file_size, provider_file_id: "file-#{SecureRandom.hex(4)}",
                                       status: "ready", metadata: { "type" => "bank_statement" }, created_at: created_at)
    end
end
