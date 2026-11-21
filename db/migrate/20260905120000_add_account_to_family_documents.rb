class AddAccountToFamilyDocuments < ActiveRecord::Migration[8.1]
  # Who may read a document is decided by its account, so the account moves out of `metadata`
  # into a column that can be joined and indexed. Nullable: a tax return or a contract has none.
  def up
    # Deleting the account clears a document's account rather than blocking the deletion. A
    # statement's document keeps its statement link in metadata, so FamilyDocument.readable_by's
    # statement-role check still applies to it.
    add_reference :family_documents, :account, type: :uuid, null: true, index: true,
                  foreign_key: { on_delete: :nullify }

    # Backfill from metadata. The id is matched as text against the strict UUID form, so a
    # malformed value matches nothing instead of failing a `::uuid` cast, and only within the
    # document's own family.
    execute <<~SQL
      UPDATE family_documents
      SET account_id = accounts.id
      FROM accounts
      WHERE family_documents.metadata->>'account_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND accounts.id::text = lower(family_documents.metadata->>'account_id')
        AND accounts.family_id = family_documents.family_id
    SQL
  end

  def down
    remove_reference :family_documents, :account, foreign_key: true
  end
end
