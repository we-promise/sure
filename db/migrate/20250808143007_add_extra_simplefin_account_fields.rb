class AddExtraSimplefinAccountFields < ActiveRecord::Migration[7.2]
  def change
    add_column :simplefin_accounts, :extra, :jsonb
    add_column :simplefin_accounts, :org_data, :jsonb
  end
end
