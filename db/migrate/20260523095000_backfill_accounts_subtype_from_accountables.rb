class BackfillAccountsSubtypeFromAccountables < ActiveRecord::Migration[7.2]
  def up
    say_with_time "Backfilling accounts.subtype from delegated accountables" do
      backfill_from("credit_cards")
      backfill_from("cryptos")
      backfill_from("depositories")
      backfill_from("investments")
      backfill_from("loans")
      backfill_from("other_assets")
      backfill_from("other_liabilities")
      backfill_from("properties")
      backfill_from("vehicles")
    end
  end

  def down
    # No-op: we can't reliably restore prior NULL vs value state.
  end

  private
    def backfill_from(table_name)
      type_name = table_name.classify

      execute(<<~SQL)
        UPDATE accounts
        SET subtype = #{table_name}.subtype
        FROM #{table_name}
        WHERE accounts.accountable_type = '#{type_name}'
          AND accounts.accountable_id = #{table_name}.id
          AND accounts.subtype IS NULL
          AND #{table_name}.subtype IS NOT NULL
      SQL
    end
end
