# Audit trail for security-sensitive account operations that had no record
# at all before this: API key creation/revocation, MFA enable/disable,
# password changes. Deliberately a separate table from sso_audit_logs
# (app/models/sso_audit_log.rb) rather than repurposing it — that model's
# name, its `provider` column, and its existing 12 call sites are all
# SSO-specific; folding unrelated event types into it would make "Sso" a
# misnomer and risk touching working code for no benefit.
class CreateSecurityAuditLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :security_audit_logs, id: :uuid do |t|
      # Nullable, not the FK's on_delete: :nullify, matching
      # debug_log_entries: an audit trail should outlive the account it's
      # about (an admin investigating a deleted account still needs to see
      # what it did beforehand), not disappear or block the deletion.
      t.uuid :user_id
      t.string :event_type, null: false
      t.string :ip_address
      t.string :user_agent
      # AR-encrypted (see SecurityAuditLog) rather than folded into `metadata`
      # (plain jsonb): these rows deliberately outlive the user (see the FK
      # below), so this is the only copy of the user's email left once the
      # account is gone, and it needs the same encryption boundary that
      # `User#email` has.
      t.text :user_email
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :security_audit_logs, :user_id
    add_index :security_audit_logs, [ :user_id, :created_at ]
    add_index :security_audit_logs, :event_type
    add_index :security_audit_logs, :created_at

    add_foreign_key :security_audit_logs, :users, on_delete: :nullify
  end
end
