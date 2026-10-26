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

  test "defaults kind to other" do
    doc = @family.family_documents.create!(filename: "note.txt")
    assert_equal "other", doc.kind
  end

  test "validates kind inclusion" do
    doc = FamilyDocument.new(family: @family, filename: "w2.pdf", kind: "horoscope")
    assert_not doc.valid?
    assert_includes doc.errors[:kind], "is not included in the list"
  end

  test "accepts every declared kind" do
    FamilyDocument::KINDS.each do |kind|
      doc = FamilyDocument.new(family: @family, filename: "doc.pdf", kind: kind)
      assert doc.valid?, "#{kind} should be valid: #{doc.errors.full_messages.to_sentence}"
    end
  end

  test "validates tax year range" do
    doc = FamilyDocument.new(family: @family, filename: "w2.pdf", kind: "tax_form")

    doc.tax_year = 2025
    assert doc.valid?

    doc.tax_year = Date.current.year + 1
    assert doc.valid?, "next year's early forms are allowed"

    doc.tax_year = Date.current.year + 2
    assert_not doc.valid?

    doc.tax_year = FamilyDocument::MIN_TAX_YEAR - 1
    assert_not doc.valid?
  end

  test "validates issuer name and title length" do
    doc = FamilyDocument.new(
      family: @family,
      filename: "policy.pdf",
      issuer_name: "a" * (FamilyDocument::ISSUER_NAME_MAX_LENGTH + 1),
      title: "b" * (FamilyDocument::TITLE_MAX_LENGTH + 1)
    )

    assert_not doc.valid?
    assert doc.errors[:issuer_name].any?
    assert doc.errors[:title].any?
  end

  test "normalizes issuer name and title whitespace" do
    doc = FamilyDocument.new(family: @family, filename: "w2.pdf", issuer_name: "  Acme   Payroll ", title: "   ")

    assert_equal "Acme Payroll", doc.issuer_name
    assert_nil doc.title
  end

  test "validates content digest format and uniqueness per family" do
    digest = FamilyDocument.content_digest("bytes")
    @family.family_documents.create!(filename: "a.txt", content_sha256: digest)

    duplicate = @family.family_documents.new(filename: "b.txt", content_sha256: digest)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:content_sha256], "has already been uploaded for this family"

    other_family = families(:empty).family_documents.new(filename: "b.txt", content_sha256: digest)
    assert other_family.valid?

    malformed = @family.family_documents.new(filename: "c.txt", content_sha256: "not-a-digest")
    assert_not malformed.valid?
  end

  test "maps classifier document types onto kinds" do
    assert_equal "account_statement", FamilyDocument.kind_for_import_type("bank_statement")
    assert_equal "account_statement", FamilyDocument.kind_for_import_type("credit_card_statement")
    assert_equal "account_statement", FamilyDocument.kind_for_import_type("account_statement")
    assert_equal "investment_report", FamilyDocument.kind_for_import_type("investment_statement")
    assert_equal "contract", FamilyDocument.kind_for_import_type("contract")
    assert_equal "other", FamilyDocument.kind_for_import_type("financial_document")
    assert_equal "other", FamilyDocument.kind_for_import_type(nil)
    assert_equal "other", FamilyDocument.kind_for_import_type("unknown")
  end

  test "every classifier document type maps to a kind" do
    Import::DOCUMENT_TYPES.each do |type|
      assert_includes FamilyDocument::KINDS, FamilyDocument.kind_for_import_type(type)
    end
  end

  test "kind label is translated in every supported locale" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      FamilyDocument::KINDS.each do |kind|
        key = "activerecord.attributes.family_document.kinds.#{kind}"
        assert I18n.exists?(key, locale), "missing #{locale} translation for #{key}"
      end
    end

    assert_equal "Pay stub", FamilyDocument.new(kind: "pay_stub").kind_label
    I18n.with_locale(:de) { assert_equal "Gehaltsabrechnung", FamilyDocument.kind_label("pay_stub") }
  end

  test "display name prefers title over filename" do
    assert_equal "2024_tax_return.pdf", @document.display_name

    @document.title = "2024 federal return"
    assert_equal "2024 federal return", @document.display_name
  end

  test "of_kind and for_tax_year scopes filter documents" do
    w2 = @family.family_documents.create!(filename: "w2.pdf", kind: "tax_form", tax_year: 2025, issuer_name: "Acme")
    @family.family_documents.create!(filename: "w2-2024.pdf", kind: "tax_form", tax_year: 2024)

    assert_equal [ w2 ], @family.family_documents.of_kind("tax_form").for_tax_year(2025).to_a
  end
end
