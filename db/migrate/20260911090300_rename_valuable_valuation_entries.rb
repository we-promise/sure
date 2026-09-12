class RenameValuableValuationEntries < ActiveRecord::Migration[8.1]
  def up
    rename_valuation_entries(from: "Manual value update", to: "Current valuation")
  end

  def down
    rename_valuation_entries(from: "Current valuation", to: "Manual value update")
  end

  private
    def rename_valuation_entries(from:, to:)
      execute <<~SQL.squish
        UPDATE entries
        SET name = #{connection.quote(to)}
        FROM accounts, valuations
        WHERE entries.account_id = accounts.id
          AND entries.entryable_type = 'Valuation'
          AND entries.entryable_id = valuations.id
          AND valuations.kind = 'reconciliation'
          AND accounts.accountable_type = 'Valuable'
          AND entries.name = #{connection.quote(from)}
      SQL
    end
end
