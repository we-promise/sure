class AddAccountToFamilyDocuments < ActiveRecord::Migration[8.1]
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
    # ON DELETE SET NULL, not the default NO ACTION. A document whose account is
    # destroyed becomes family-wide again, which is exactly what a nullable link
    # means here; without it, destroying an account that has an indexed statement
    # raises InvalidForeignKey and the whole destroy is rolled back.
    add_reference :family_documents, :account, type: :uuid, null: true, index: true,
                  foreign_key: { on_delete: :nullify }

    # Backfill from the metadata key written since the vault bridge landed.
    #
    # The pattern is the canonical 8-4-4-4-12 form, not "36 hex-or-dash
    # characters": the loose version admits 36 dashes, and `~` alone does not
    # bind Postgres to an evaluation order, so such a row could still reach a
    # `::uuid` cast and abort the whole migration. Matching the account on TEXT
    # keeps the cast off the untrusted value entirely; anything malformed
    # simply matches nothing and is skipped, which is the intended behaviour.
    #
    # The family predicate matches no row today: nothing on main ever wrote this
    # metadata key, and every writer added here assigns the column directly. It
    # states the invariant the column carries rather than leaving a raw UPDATE
    # that would silently outrank FamilyDocument#account_belongs_to_family.
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
