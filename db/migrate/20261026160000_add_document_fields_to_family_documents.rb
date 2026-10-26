class AddDocumentFieldsToFamilyDocuments < ActiveRecord::Migration[8.1]
  # The document store only knew a file's name and an untyped `metadata` hash,
  # which is enough to search it and not enough to answer "which 2025 tax forms
  # do we hold?". These columns make a document a typed record: what kind of
  # document it is, the tax year it belongs to, who issued it and when, plus the
  # content digest needed to keep one copy of a file per family.
  #
  # All additive and nullable (kind has a default), so existing rows stay valid
  # and an older app version keeps working against the new schema.
  def up
    change_table :family_documents, bulk: true do |t|
      t.string :kind, null: false, default: "other"
      t.integer :tax_year
      t.date :document_date
      t.string :issuer_name, limit: 200
      t.string :title, limit: 255
      t.string :content_sha256
    end

    # Partial: rows indexed before this migration have no digest, and their
    # bytes were never kept, so there is nothing to compute one from.
    add_index :family_documents, [ :family_id, :content_sha256 ],
              unique: true,
              where: "content_sha256 IS NOT NULL",
              name: "index_family_documents_on_family_id_and_content_sha256"
    add_index :family_documents, [ :family_id, :kind, :tax_year ]

    backfill_kinds
  end

  def down
    remove_index :family_documents, name: "index_family_documents_on_family_id_and_content_sha256"
    remove_index :family_documents, [ :family_id, :kind, :tax_year ]

    change_table :family_documents, bulk: true do |t|
      t.remove :kind, :tax_year, :document_date, :issuer_name, :title, :content_sha256
    end
  end

  # Backfill kind from the classifier type the two writers already store in
  # metadata. Anything unrecognised stays "other", the column default. Mirrors
  # FamilyDocument::IMPORT_DOCUMENT_TYPE_KINDS, written out so the migration
  # does not change meaning if that constant does.
  def backfill_kinds
    execute <<~SQL
      UPDATE family_documents
      SET kind = CASE metadata->>'type'
        WHEN 'account_statement' THEN 'account_statement'
        WHEN 'bank_statement' THEN 'account_statement'
        WHEN 'credit_card_statement' THEN 'account_statement'
        WHEN 'investment_statement' THEN 'investment_report'
        WHEN 'contract' THEN 'contract'
        ELSE 'other'
      END
      WHERE metadata ? 'type'
    SQL
  end
end
