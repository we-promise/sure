class ConstrainRecurringEnumAndCurrencyColumns < ActiveRecord::Migration[7.2]
  # These invariants were enforced only by Rails: an enum assignment raises in
  # Ruby, and "an allocation is denominated in its occurrence's currency" was a
  # model validation. Neither survives insert_all, a rake task or a console
  # session, and this is a ledger. No values change.
  def up
    add_check_constraint :recurring_occurrences,
                         "status IN ('scheduled', 'paid', 'skipped', 'missed')",
                         name: "chk_recurring_occurrences_status"

    add_check_constraint :recurring_occurrences,
                         "closed_source IS NULL OR closed_source IN ('auto', 'user')",
                         name: "chk_recurring_occurrences_closed_source"

    add_check_constraint :recurring_allocations,
                         "state IN ('suggested', 'confirmed')",
                         name: "chk_recurring_allocations_state"

    add_check_constraint :recurring_allocations,
                         "source IN ('auto_matched', 'user_confirmed', 'user_created')",
                         name: "chk_recurring_allocations_source"

    # Currency equality spans two tables, so a CHECK cannot express it. A
    # composite foreign key can: the pair (occurrence, currency) must exist on
    # the occurrence itself, which makes a mismatch unrepresentable rather
    # than merely invalid.
    execute <<~SQL
      UPDATE recurring_allocations a
      SET currency = o.currency
      FROM recurring_occurrences o
      WHERE o.id = a.recurring_occurrence_id
        AND a.currency IS DISTINCT FROM o.currency
    SQL

    add_index :recurring_occurrences, [ :id, :currency ],
              unique: true, name: "idx_recurring_occurrences_id_currency"

    execute <<~SQL
      ALTER TABLE recurring_allocations
        ADD CONSTRAINT fk_recurring_allocations_currency_matches_occurrence
        FOREIGN KEY (recurring_occurrence_id, currency)
        REFERENCES recurring_occurrences (id, currency)
        ON DELETE CASCADE
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE recurring_allocations
        DROP CONSTRAINT IF EXISTS fk_recurring_allocations_currency_matches_occurrence
    SQL
    remove_index :recurring_occurrences, name: "idx_recurring_occurrences_id_currency"
    remove_check_constraint :recurring_allocations, name: "chk_recurring_allocations_source"
    remove_check_constraint :recurring_allocations, name: "chk_recurring_allocations_state"
    remove_check_constraint :recurring_occurrences, name: "chk_recurring_occurrences_closed_source"
    remove_check_constraint :recurring_occurrences, name: "chk_recurring_occurrences_status"
  end
end
