class MigrateAccountProvidersData < ActiveRecord::Migration[7.2]
  def up
    # Migrate Plaid accounts
    execute <<-SQL
      INSERT INTO account_providers (id, account_id, provider_type, provider_id, created_at, updated_at)
      SELECT
        gen_random_uuid(),
        accounts.id,
        'PlaidAccount',
        accounts.plaid_account_id,
        NOW(),
        NOW()
      FROM accounts
      WHERE accounts.plaid_account_id IS NOT NULL
    SQL

    # Migrate SimpleFin accounts
    execute <<-SQL
      INSERT INTO account_providers (id, account_id, provider_type, provider_id, created_at, updated_at)
      SELECT
        gen_random_uuid(),
        accounts.id,
        'SimplefinAccount',
        accounts.simplefin_account_id,
        NOW(),
        NOW()
      FROM accounts
      WHERE accounts.simplefin_account_id IS NOT NULL
    SQL
  end

  def down
    # Delete all account provider records
    execute "DELETE FROM account_providers"
  end
end
