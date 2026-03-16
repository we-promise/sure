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
end
