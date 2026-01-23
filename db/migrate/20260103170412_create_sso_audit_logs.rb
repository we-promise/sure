class CreateSsoAuditLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :sso_audit_logs, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: true, null: true
      t.string :event_type, null: false
      t.string :provider
      t.string :ip_address
      t.string :user_agent
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :sso_audit_logs, :event_type
    add_index :sso_audit_logs, :created_at
    add_index :sso_audit_logs, [ :user_id, :created_at ]
  end
end
