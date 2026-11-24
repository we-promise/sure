require "test_helper"

class FamilyDocumentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @document = family_documents(:tax_return)
  end

  test "belongs to a family" do
    assert_equal @family, @document.family
  end

  test "validates filename presence" do
    doc = FamilyDocument.new(family: @family, status: "pending")
    assert_not doc.valid?
    assert_includes doc.errors[:filename], "can't be blank"
  end

  test "validates status inclusion" do
    doc = FamilyDocument.new(family: @family, filename: "test.pdf", status: "invalid")
    assert_not doc.valid?
    assert_includes doc.errors[:status], "is not included in the list"
  end

  test "ready scope returns only ready documents" do
    ready_docs = @family.family_documents.ready
    assert ready_docs.all? { |d| d.status == "ready" }
    assert_not_includes ready_docs, family_documents(:pending_doc)
  end

  test "mark_ready! updates status" do
    doc = family_documents(:pending_doc)
    doc.mark_ready!
    assert_equal "ready", doc.reload.status
  end

  test "mark_error! updates status and metadata" do
    doc = family_documents(:pending_doc)
    doc.mark_error!("Upload failed")
    doc.reload
    assert_equal "error", doc.status
    assert_equal "Upload failed", doc.metadata["error"]
  end

  test "supported_extension? returns true for supported types" do
    doc = FamilyDocument.new(filename: "report.pdf")
    assert doc.supported_extension?
  end

  test "supported_extension? returns false for unsupported types" do
    doc = FamilyDocument.new(filename: "video.mp4")
    assert_not doc.supported_extension?
  end

  test "readable_by returns only ready documents, and nothing when indexing failed" do
    user = users(:family_admin)
    readable = @family.family_documents.readable_by(user)
    assert_includes readable, family_documents(:tax_return)

    pending_doc = family_documents(:pending_doc)
    assert_not_includes readable, pending_doc

    failed = @family.family_documents.create!(filename: "borked.pdf", status: "error")
    assert_not_includes @family.family_documents.readable_by(user), failed

    pending_doc.update!(status: "unreadable")
    assert_not_includes @family.family_documents.readable_by(user), pending_doc
  end

  # A PDF processed before documents recorded their statement (main's #5701) could come from any
  # account, so nobody reads it until a migration links it.
  test "readable_by hides a processed PDF whose statement is unknown, from an admin too" do
    legacy = @family.family_documents.create!(filename: "old.pdf", status: "ready", metadata: { "type" => "bank_statement" })
    linked = @family.family_documents.create!(filename: "new.pdf", status: "ready",
                                              metadata: { "type" => "bank_statement", "pdf_import_id" => SecureRandom.uuid })
    upload = @family.family_documents.create!(filename: "notes.txt", status: "ready", metadata: {})

    readable = @family.family_documents.readable_by(users(:family_admin))

    assert_not_includes readable, legacy
    assert_includes readable, linked
    assert_includes readable, upload
  end
end
