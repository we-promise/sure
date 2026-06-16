class AddDisabledAtToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :disabled_at, :datetime

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE accounts
          SET disabled_at = updated_at
          WHERE status = 'disabled'
            AND disabled_at IS NULL
        SQL
      end
    end
  end
end
