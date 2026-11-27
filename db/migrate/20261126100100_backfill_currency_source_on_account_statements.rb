# Every statement now stores its currency and where it came from.
#
# A linked statement in its account's currency, or with none, takes the
# account's; one in another currency was picked by hand. An unlinked
# statement in its family's currency, or with none, holds the family default,
# which a currency the document names may still replace. One in another
# currency was read from the document. A family without a currency falls back
# to the column default, USD.
class BackfillCurrencySourceOnAccountStatements < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE account_statements
      SET currency = COALESCE(account_statements.currency, accounts.currency, families.currency, 'USD'),
          currency_source = CASE
            WHEN account_statements.currency IS NULL OR account_statements.currency = accounts.currency THEN 'account'
            ELSE 'user'
          END
      FROM accounts, families
      WHERE accounts.id = account_statements.account_id
        AND families.id = account_statements.family_id
        AND account_statements.currency_source IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE account_statements
      SET currency = COALESCE(account_statements.currency, families.currency, 'USD'),
          currency_source = CASE
            WHEN account_statements.currency IS NULL OR account_statements.currency = COALESCE(families.currency, 'USD') THEN 'family_default'
            ELSE 'document'
          END
      FROM families
      WHERE families.id = account_statements.family_id
        AND account_statements.account_id IS NULL
        AND account_statements.currency_source IS NULL
    SQL

    change_column_null :account_statements, :currency, false
    change_column_null :account_statements, :currency_source, false
  end

  # The currencies filled in stay; they are what the statements showed.
  def down
    change_column_null :account_statements, :currency_source, true
    change_column_null :account_statements, :currency, true
  end
end
