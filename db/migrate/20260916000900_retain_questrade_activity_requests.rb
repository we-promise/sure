class RetainQuestradeActivityRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :questrade_accounts, :activities_fetch_request, :jsonb
    add_column :questrade_accounts, :activities_fetch_revision, :bigint, null: false, default: 0
    add_column :questrade_accounts, :activities_fetch_due_at, :datetime
    add_index :questrade_accounts, [ :activities_fetch_due_at, :id ],
      where: "activities_fetch_pending = true", name: "index_questrade_activity_recovery"
    add_check_constraint :questrade_accounts,
      "(activities_fetch_request IS NULL AND activities_fetch_revision = 0 AND activities_fetch_due_at IS NULL) OR " \
      "(activities_fetch_request IS NOT NULL AND activities_fetch_revision > 0)", name: "chk_questrade_activity_request"
    add_check_constraint :questrade_accounts,
      "activities_fetch_due_at IS NULL OR (activities_fetch_request IS NOT NULL AND activities_fetch_pending = true)",
      name: "chk_questrade_activity_due"
  end
end
