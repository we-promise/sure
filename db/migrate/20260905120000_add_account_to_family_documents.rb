class AddAccountToFamilyDocuments < ActiveRecord::Migration[7.2]
  # The document store had no account dimension: every search was family-wide by
  # construction, which was tolerable while only /imports fed it and stopped
  # being so once every Statement Vault upload was indexed. The link already
  # existed in `metadata`, but a jsonb key cannot be joined, indexed usefully or
  # enforced, so it becomes a real column.
  #
  # Nullable on purpose: a document with no account (a tax return, a contract)
  # is a legitimate row, and only a document that names an account it is not
  # yours to see gets filtered out.
  def up
    add_reference :family_documents, :account, type: :uuid, null: true, foreign_key: true, index: true

    # Backfill from the metadata key written since the vault bridge landed.
    #
    # The pattern is the canonical 8-4-4-4-12 form, not "36 hex-or-dash
    # characters": the loose version admits 36 dashes, and `~` alone does not
    # bind Postgres to an evaluation order, so such a row could still reach a
    # `::uuid` cast and abort the whole migration. Matching the account on TEXT
    # keeps the cast off the untrusted value entirely; anything malformed
    # simply matches nothing and is skipped, which is the intended behaviour.
    execute <<~SQL
      UPDATE family_documents
      SET account_id = accounts.id
      FROM accounts
      WHERE family_documents.metadata->>'account_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND accounts.id::text = lower(family_documents.metadata->>'account_id')
    SQL
  end

  def down
    remove_reference :family_documents, :account, foreign_key: true
  end
end
