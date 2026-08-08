class CreateBudgetShares < ActiveRecord::Migration[7.2]
  def change
    # A budget owner grants a family member read-only or read-write access to
    # their personal budget. Mirrors AccountShare's shape (see
    # 20260324100000_add_account_sharing_support.rb).
    create_table :budget_shares, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :viewer, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :permission, null: false, default: "read_only"
      t.timestamps
    end

    add_index :budget_shares, [ :owner_id, :viewer_id ], unique: true
  end
end
