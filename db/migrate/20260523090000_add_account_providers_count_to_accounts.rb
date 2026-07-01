class AddAccountProvidersCountToAccounts < ActiveRecord::Migration[7.2]
  def up
    add_column :accounts, :account_providers_count, :integer, null: false, default: 0

    execute(<<~SQL)
      UPDATE accounts
      SET account_providers_count = counts.count
      FROM (
        SELECT account_id, COUNT(*) AS count
        FROM account_providers
        GROUP BY account_id
      ) AS counts
      WHERE accounts.id = counts.account_id
    SQL
  end

  def down
    remove_column :accounts, :account_providers_count
  end
end
