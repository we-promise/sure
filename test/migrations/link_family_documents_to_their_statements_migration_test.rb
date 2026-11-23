require "test_helper"
require Rails.root.join("db/migrate/20261122120100_link_family_documents_to_their_statements")

class LinkFamilyDocumentsToTheirStatementsMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "links a processed PDF to the statement with its filename and size" do
    statement = create_statement("march.pdf", "%PDF-1.4 March")
    document = processed_document("march.pdf", statement.original_file.byte_size)

    run_migration

    assert_equal statement, document.reload.account_statement
  end

  test "leaves a processed PDF unlinked when it predates the statement's import" do
    document = processed_document("march.pdf", "%PDF-1.4 March".bytesize, created_at: 1.year.ago)
    statement = create_statement("march.pdf", "%PDF-1.4 March")

    run_migration

    assert_equal statement.original_file.byte_size, document.file_size
    assert_nil document.reload.account_statement
  end

  test "leaves a processed PDF unlinked when its statement was never imported" do
    statement = AccountStatement.create_from_upload!(family: @family, account: accounts(:connected), file: pdf_upload("march.pdf", "%PDF-1.4 March"))
    document = processed_document("march.pdf", statement.original_file.byte_size)

    run_migration

    assert_nil document.reload.account_statement
  end

  test "leaves a processed PDF unlinked when no statement has its size" do
    create_statement("march.pdf", "%PDF-1.4 March")
    document = processed_document("march.pdf", 1)

    run_migration

    assert_nil document.reload.account_statement
  end

  test "leaves a processed PDF unlinked when two statements could be its own" do
    first = create_statement("march.pdf", "%PDF-1.4 March A")
    create_statement("march.pdf", "%PDF-1.4 March B")
    document = processed_document("march.pdf", first.original_file.byte_size)

    run_migration

    assert_nil document.reload.account_statement
  end

  test "leaves files uploaded straight to the store alone" do
    statement = create_statement("notes.pdf", "%PDF-1.4 Notes")
    document = @family.family_documents.create!(filename: "notes.pdf", file_size: statement.original_file.byte_size,
                                                provider_file_id: "file-direct", status: "ready", metadata: {})

    run_migration

    assert_nil document.reload.account_statement
  end

  test "does not link a statement of another family" do
    statement = AccountStatement.create_from_upload!(family: families(:empty), account: nil, file: pdf_upload("march.pdf", "%PDF-1.4 March"))
    PdfImport.create_from_statement!(statement: statement)
    document = processed_document("march.pdf", statement.original_file.byte_size)

    run_migration

    assert_nil document.reload.account_statement
  end

  private
    def run_migration
      ActiveRecord::Migration.suppress_messages { LinkFamilyDocumentsToTheirStatements.new.up }
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
