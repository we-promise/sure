class BackfillInstallmentSubtypeOnAccounts < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE accounts
      SET subtype = 'installment'
      WHERE subtype IS NULL
        AND id IN (SELECT account_id FROM installments)
    SQL
  end

  def down
    execute <<~SQL
      UPDATE accounts
      SET subtype = NULL
      WHERE subtype = 'installment'
        AND id IN (SELECT account_id FROM installments)
    SQL
  end
end
