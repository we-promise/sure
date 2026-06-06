class EnforcePocketsCurrencyPresent < ActiveRecord::Migration[7.2]
  def up
    # Backfill rows that received the empty-string default before this constraint
    execute <<~SQL
      UPDATE pockets
      SET currency = accounts.currency
      FROM accounts
      WHERE pockets.account_id = accounts.id
        AND (pockets.currency IS NULL OR pockets.currency = '')
    SQL

    change_column_default :pockets, :currency, from: "", to: nil
    add_check_constraint :pockets, "currency <> ''", name: "chk_pockets_currency_present"
  end

  def down
    remove_check_constraint :pockets, name: "chk_pockets_currency_present"
    change_column_default :pockets, :currency, from: nil, to: ""
  end
end
