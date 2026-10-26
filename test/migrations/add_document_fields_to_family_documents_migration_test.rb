# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261026160000_add_document_fields_to_family_documents")

# Rows written before the migration only know their classifier type, in
# metadata["type"]. The backfill must give each of them the same kind a new
# upload of that type would get, and leave everything else as "other".
class AddDocumentFieldsToFamilyDocumentsMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "backfilled kinds agree with the runtime mapping" do
    documents = (Import::DOCUMENT_TYPES + %w[account_statement]).index_with do |type|
      @family.family_documents.create!(filename: "#{type}.pdf", metadata: { "type" => type })
    end
    documents.each_value { |document| document.update_columns(kind: "other") }

    run_backfill

    documents.each do |type, document|
      assert_equal FamilyDocument.kind_for_import_type(type), document.reload.kind, "type #{type}"
    end
  end

  test "rows without a classifier type keep their kind" do
    document = @family.family_documents.create!(filename: "notes.txt", kind: "receipt", metadata: {})

    run_backfill

    assert_equal "receipt", document.reload.kind
  end

  private
    def run_backfill
      ActiveRecord::Migration.suppress_messages do
        AddDocumentFieldsToFamilyDocuments.new.backfill_kinds
      end
    end
end
