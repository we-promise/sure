class PreserveLegacyGoldInvestmentsWithSecurities < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE investments
      SET gold_form = 'digital'
      WHERE subtype = 'gold'
        AND gold_form = 'physical'
        AND EXISTS (
          SELECT 1
          FROM accounts
          WHERE accounts.accountable_type = 'Investment'
            AND accounts.accountable_id = investments.id
            AND (
              EXISTS (SELECT 1 FROM holdings WHERE holdings.account_id = accounts.id)
              OR EXISTS (
                SELECT 1 FROM entries
                WHERE entries.account_id = accounts.id
                  AND entries.entryable_type = 'Trade'
              )
            )
        )
    SQL
  end

  def down
    # The prior form cannot be inferred safely once a legacy account has been
    # corrected, so this data migration intentionally has no reversal.
  end
end
