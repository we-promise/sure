# The bills subsystem's whole schema in one migration, squashed from the
# feature branch's incremental steps. DDL and the data backfills the
# incremental path carried run in their original order, so an instance
# upgrading with existing recurring_transactions rows lands on exactly the
# data the step-by-step path produced.
class CreateBillsSubsystem < ActiveRecord::Migration[7.2]
  def up
    # -- Series basics: payment link, autopay flag, freeform notes ----------
    add_column :recurring_transactions, :payment_url, :string
    add_column :recurring_transactions, :autopay, :boolean, default: false, null: false
    add_column :recurring_transactions, :notes, :text

    # -- Recurrence rules: explicit schedule definitions per series ---------
    create_table :recurrence_rules, id: :uuid do |t|
      t.references :recurring_transaction, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.string :frequency, null: false
      t.integer :interval, null: false, default: 1
      t.integer :day_of_month
      t.integer :weekday
      t.integer :weekday_ordinal
      t.integer :month_of_year
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :recurrence_rules, [ :recurring_transaction_id, :position ], unique: true

    add_check_constraint :recurrence_rules, "interval > 0", name: "chk_recurrence_rules_interval_positive"
    add_check_constraint :recurrence_rules,
      "day_of_month IS NULL OR (day_of_month BETWEEN -1 AND 31 AND day_of_month <> 0)",
      name: "chk_recurrence_rules_day_of_month_range"
    add_check_constraint :recurrence_rules, "weekday IS NULL OR weekday BETWEEN 0 AND 6",
      name: "chk_recurrence_rules_weekday_range"
    add_check_constraint :recurrence_rules,
      "weekday_ordinal IS NULL OR (weekday_ordinal BETWEEN -1 AND 5 AND weekday_ordinal <> 0)",
      name: "chk_recurrence_rules_weekday_ordinal_range"
    add_check_constraint :recurrence_rules, "month_of_year IS NULL OR month_of_year BETWEEN 1 AND 12",
      name: "chk_recurrence_rules_month_of_year_range"
    # An ordinal is meaningless without a weekday; a weekday without an ordinal
    # is legal only for weekly rules, which the model enforces (constraints
    # here stay shape-level so errors can carry messages).
    add_check_constraint :recurrence_rules,
      "weekday_ordinal IS NULL OR weekday IS NOT NULL",
      name: "chk_recurrence_rules_ordinal_requires_weekday"
    add_check_constraint :recurrence_rules,
      "NOT (day_of_month IS NOT NULL AND weekday IS NOT NULL)",
      name: "chk_recurrence_rules_single_day_spec"

    change_table :recurring_transactions, bulk: true do |t|
      t.date :anchor_date
      t.string :end_mode, null: false, default: "never"
      t.date :end_on
      t.integer :end_after_count
      t.string :weekend_adjust, null: false, default: "none"
      t.string :holiday_calendar
    end

    # Every existing series is monthly on expected_day_of_month; give each an
    # explicit rule saying exactly that, anchored on its last occurrence. A
    # series with zero rules stays legal (Schedule synthesizes the implicit
    # monthly rule), so this backfill is a normalization, not a requirement.
    execute <<~SQL
      INSERT INTO recurrence_rules (id, recurring_transaction_id, frequency, interval, day_of_month, position, created_at, updated_at)
      SELECT gen_random_uuid(), id, 'monthly', 1, expected_day_of_month, 0, NOW(), NOW()
      FROM recurring_transactions
    SQL

    execute <<~SQL
      UPDATE recurring_transactions SET anchor_date = last_occurrence_date WHERE anchor_date IS NULL
    SQL

    # -- Bill attributes on the series ---------------------------------------
    change_table :recurring_transactions, bulk: true do |t|
      # Classification & linkage
      t.string :bill_type, null: false, default: "bill"
      t.references :category, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.uuid :replaced_by_id

      # Amount semantics
      t.string :amount_strategy, null: false, default: "fixed"
      t.decimal :amount_tolerance_pct, precision: 5, scale: 2, null: false, default: 7.5

      # Per-bill knobs (NULL = app default)
      t.integer :notify_days_before
      t.integer :upcoming_window_days
      t.integer :overdue_grace_days
      t.integer :match_days_early, null: false, default: 2
      t.integer :match_days_late, null: false, default: 7

      # Subscription lifecycle
      t.date :renews_on
      t.date :trial_ends_on
      t.date :cancelled_on

      # Matcher memory (transparent, user-visible)
      t.jsonb :matcher_hints, null: false, default: {}
    end

    add_foreign_key :recurring_transactions, :recurring_transactions,
                    column: :replaced_by_id, on_delete: :nullify

    # A transfer-shaped series is a payment obligation between two of the
    # user's own accounts (credit-card payment, loan payment); income is an
    # inflow (expenses are stored positive); everything else is a bill.
    execute <<~SQL
      UPDATE recurring_transactions
      SET bill_type = CASE
        WHEN destination_account_id IS NOT NULL THEN 'transfer'
        WHEN amount < 0 THEN 'income'
        ELSE 'bill'
      END
    SQL

    # -- Identity index rework ------------------------------------------------
    # The four identity indexes included `amount`, so any price change forked
    # the series into a second row instead of updating the first --
    # auto-detection is amount-scoped by construction. Identity becomes
    # (family, account, [destination], merchant|name, currency, dedup_scope):
    # price changes update `amount` freely, and the rare LEGITIMATE second
    # series for one identifier (three Twitch tiers) carries a discriminator
    # in dedup_scope instead.
    add_column :recurring_transactions, :dedup_scope, :string, null: false, default: ""

    stamp_existing_price_forks

    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_merchant"
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name"
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_merchant"
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_name"

    add_index :recurring_transactions,
              [ :family_id, :account_id, :merchant_id, :amount, :currency, :dedup_scope ],
              unique: true, name: "idx_recurring_txns_acct_merchant",
              where: "merchant_id IS NOT NULL AND destination_account_id IS NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :name, :amount, :currency, :dedup_scope ],
              unique: true, name: "idx_recurring_txns_acct_name",
              where: "name IS NOT NULL AND merchant_id IS NULL AND destination_account_id IS NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :destination_account_id, :merchant_id, :amount, :currency, :dedup_scope ],
              unique: true, name: "idx_recurring_txns_pair_merchant",
              where: "destination_account_id IS NOT NULL AND merchant_id IS NOT NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :destination_account_id, :name, :amount, :currency, :dedup_scope ],
              unique: true, name: "idx_recurring_txns_pair_name",
              where: "destination_account_id IS NOT NULL AND name IS NOT NULL AND merchant_id IS NULL"

    # Session imports resolve cross-chunk references through persisted source
    # mappings, and occurrences joined that contract when allocations started
    # arriving in later chunks than the cycles they pay.
    remove_check_constraint :import_source_mappings, name: "chk_import_source_mappings_source_type"
    add_check_constraint :import_source_mappings,
                         "source_type IN ('Account', 'Category', 'Tag', 'Merchant', 'RecurringTransaction', 'RecurringOccurrence', 'Transaction', 'Budget', 'Security', 'Rule')",
                         name: "chk_import_source_mappings_source_type"
    remove_check_constraint :import_source_mappings, name: "chk_import_source_mappings_target_type"
    add_check_constraint :import_source_mappings,
                         "target_type IN ('Account', 'Category', 'Tag', 'Merchant', 'RecurringTransaction', 'RecurringOccurrence', 'Transaction', 'Budget', 'Security', 'Rule')",
                         name: "chk_import_source_mappings_target_type"

    # -- Occurrences, allocations, rejections, price history -----------------
    # One row per expected obligation instance. Materialized only inside a
    # rolling window or when carrying state; closed rows are immutable
    # history that survives any edit to the series definition.
    create_table :recurring_occurrences, id: :uuid do |t|
      t.references :recurring_transaction, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.references :family, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.date :original_due_on, null: false
      t.date :due_on, null: false
      t.string :currency, null: false
      t.decimal :expected_amount, precision: 19, scale: 4
      t.string :status, null: false, default: "scheduled"
      t.date :snoozed_until
      t.datetime :closed_at
      t.text :notes
      t.string :closed_source

      t.timestamps
    end

    add_index :recurring_occurrences, [ :recurring_transaction_id, :original_due_on ],
              unique: true, name: "idx_recurring_occurrences_identity"
    add_index :recurring_occurrences, [ :family_id, :status, :due_on ]
    add_index :recurring_occurrences, [ :family_id, :due_on ]
    add_check_constraint :recurring_occurrences,
                         "(status = 'scheduled') = (closed_at IS NULL)",
                         name: "chk_recurring_occurrences_closed_state"

    # Links payments to occurrences with an amount, which is what makes
    # partial payments first-class: several allocations sum toward one
    # obligation, and one entry can cover several. entry_id is nullable from
    # birth for payments recorded without a bank transaction, and nullified
    # on entry deletion so the payment record survives.
    create_table :recurring_allocations, id: :uuid do |t|
      t.references :recurring_occurrence, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.decimal :allocated_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.decimal :source_amount, precision: 19, scale: 4
      t.string :source_currency
      t.string :state, null: false, default: "confirmed"
      t.string :source, null: false
      t.decimal :match_confidence, precision: 5, scale: 4
      t.jsonb :match_signals, null: false, default: {}
      t.date :paid_on

      t.timestamps
    end

    add_index :recurring_allocations, [ :recurring_occurrence_id, :entry_id ],
              unique: true, where: "entry_id IS NOT NULL",
              name: "idx_recurring_allocations_entry_once"
    add_index :recurring_allocations, :recurring_occurrence_id
    add_check_constraint :recurring_allocations, "allocated_amount > 0",
                         name: "chk_recurring_allocations_amount_positive"

    # A rejected (series, entry) pair is never suggested again.
    create_table :recurring_match_rejections, id: :uuid do |t|
      t.references :recurring_transaction, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.references :entry, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false

      t.timestamps
    end

    add_index :recurring_match_rejections, [ :recurring_transaction_id, :entry_id ],
              unique: true, name: "idx_recurring_match_rejections_pair"

    # Price history per series, feeding subscription intelligence.
    create_table :recurring_price_changes, id: :uuid do |t|
      t.references :recurring_transaction, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      t.date :effective_on, null: false
      t.decimal :previous_amount, precision: 19, scale: 4, null: false
      t.decimal :new_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :source, null: false
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }, index: false

      t.timestamps
    end

    add_index :recurring_price_changes, [ :recurring_transaction_id, :effective_on ],
              unique: true, name: "idx_recurring_price_changes_identity"

    # -- Enum and currency invariants, in the database ------------------------
    # These invariants were enforced only by Rails: an enum assignment raises
    # in Ruby, and "an allocation is denominated in its occurrence's currency"
    # was a model validation. Neither survives insert_all, a rake task or a
    # console session, and this is a ledger. No values change.
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

    # -- iCal feed token on the family ----------------------------------------
    add_column :families, :bills_feed_token, :string
    add_index :families, :bills_feed_token, unique: true

    # -- Entry-side delete performance ----------------------------------------
    # Entry deletes enforce cascade/nullify on these tables; without a
    # leading entry_id index each delete walks the whole table.
    add_index :recurring_match_rejections, :entry_id
    add_index :recurring_price_changes, :entry_id

    # The frequency enum raises only in Ruby; a row written past the model
    # (insert_all, a rake task, a console session) could carry a frequency the
    # schedule engine cannot generate occurrences for.
    add_check_constraint :recurrence_rules,
                         "frequency IN ('weekly', 'monthly', 'yearly')",
                         name: "chk_recurrence_rules_frequency"
  end

  def down
    remove_check_constraint :recurrence_rules, name: "chk_recurrence_rules_frequency"

    remove_index :recurring_price_changes, :entry_id
    remove_index :recurring_match_rejections, :entry_id

    remove_index :families, :bills_feed_token
    remove_column :families, :bills_feed_token

    execute <<~SQL
      ALTER TABLE recurring_allocations
        DROP CONSTRAINT IF EXISTS fk_recurring_allocations_currency_matches_occurrence
    SQL
    remove_index :recurring_occurrences, name: "idx_recurring_occurrences_id_currency"
    remove_check_constraint :recurring_allocations, name: "chk_recurring_allocations_source"
    remove_check_constraint :recurring_allocations, name: "chk_recurring_allocations_state"
    remove_check_constraint :recurring_occurrences, name: "chk_recurring_occurrences_closed_source"
    remove_check_constraint :recurring_occurrences, name: "chk_recurring_occurrences_status"

    drop_table :recurring_price_changes
    drop_table :recurring_match_rejections
    drop_table :recurring_allocations
    drop_table :recurring_occurrences

    remove_check_constraint :import_source_mappings, name: "chk_import_source_mappings_source_type"
    add_check_constraint :import_source_mappings,
                         "source_type IN ('Account', 'Category', 'Tag', 'Merchant', 'RecurringTransaction', 'Transaction', 'Budget', 'Security', 'Rule')",
                         name: "chk_import_source_mappings_source_type"
    remove_check_constraint :import_source_mappings, name: "chk_import_source_mappings_target_type"
    add_check_constraint :import_source_mappings,
                         "target_type IN ('Account', 'Category', 'Tag', 'Merchant', 'RecurringTransaction', 'Transaction', 'Budget', 'Security', 'Rule')",
                         name: "chk_import_source_mappings_target_type"

    # The up migration widens the uniqueness key with dedup_scope, so rows that
    # differ only in scope, deliberate price forks, can exist by the time anyone
    # rolls back. Recreating the narrower indexes would then fail mid-migration,
    # or force a choice about which fork to destroy. Refusing with a clear
    # message beats either. A database that never grew such rows rolls back
    # exactly as before.
    # One check per restored index, mirroring its exact columns and predicate.
    # A single broad grouping missed pairs the narrower merchant indexes would
    # still reject, and the failure would land after the bills tables were
    # already dropped.
    # account_id is the one nullable indexed column, and the indexes treat
    # NULLs as distinct: two accountless rows never collide, so grouping them
    # here would refuse a rollback PostgreSQL can perform.
    collision_checks = [
      [ "family_id, account_id, merchant_id, amount, currency",
        "account_id IS NOT NULL AND merchant_id IS NOT NULL AND destination_account_id IS NULL" ],
      [ "family_id, account_id, name, amount, currency",
        "account_id IS NOT NULL AND name IS NOT NULL AND merchant_id IS NULL AND destination_account_id IS NULL" ],
      [ "family_id, account_id, destination_account_id, merchant_id, amount, currency",
        "account_id IS NOT NULL AND destination_account_id IS NOT NULL AND merchant_id IS NOT NULL" ],
      [ "family_id, account_id, destination_account_id, name, amount, currency",
        "account_id IS NOT NULL AND destination_account_id IS NOT NULL AND name IS NOT NULL AND merchant_id IS NULL" ]
    ]
    forked = collision_checks.any? do |columns, predicate|
      ActiveModel::Type::Boolean.new.cast(select_value(<<~SQL))
        SELECT EXISTS (
          SELECT 1 FROM recurring_transactions
          WHERE #{predicate}
          GROUP BY #{columns}
          HAVING COUNT(*) > 1
        )
      SQL
    end
    if forked
      raise ActiveRecord::IrreversibleMigration,
            "recurring_transactions holds rows distinguished only by dedup_scope " \
            "(price-forked series). The pre-bills unique indexes cannot be recreated " \
            "without losing one of each pair. Remove or merge the forked series first."
    end

    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_merchant"
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name"
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_merchant"
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_name"

    add_index :recurring_transactions,
              [ :family_id, :account_id, :merchant_id, :amount, :currency ],
              unique: true, name: "idx_recurring_txns_acct_merchant",
              where: "merchant_id IS NOT NULL AND destination_account_id IS NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :name, :amount, :currency ],
              unique: true, name: "idx_recurring_txns_acct_name",
              where: "name IS NOT NULL AND merchant_id IS NULL AND destination_account_id IS NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :destination_account_id, :merchant_id, :amount, :currency ],
              unique: true, name: "idx_recurring_txns_pair_merchant",
              where: "destination_account_id IS NOT NULL AND merchant_id IS NOT NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :destination_account_id, :name, :amount, :currency ],
              unique: true, name: "idx_recurring_txns_pair_name",
              where: "destination_account_id IS NOT NULL AND name IS NOT NULL AND merchant_id IS NULL"

    remove_column :recurring_transactions, :dedup_scope

    remove_foreign_key :recurring_transactions, column: :replaced_by_id
    change_table :recurring_transactions, bulk: true do |t|
      t.remove :bill_type, :category_id, :replaced_by_id, :amount_strategy, :amount_tolerance_pct,
               :notify_days_before, :upcoming_window_days, :overdue_grace_days,
               :match_days_early, :match_days_late, :renews_on, :trial_ends_on, :cancelled_on,
               :matcher_hints
    end

    change_table :recurring_transactions, bulk: true do |t|
      t.remove :anchor_date, :end_mode, :end_on, :end_after_count, :weekend_adjust, :holiday_calendar
    end
    drop_table :recurrence_rules

    change_table :recurring_transactions, bulk: true do |t|
      t.remove :autopay, :notes, :payment_url
    end
  end

  private
    # Rows that collide once amount leaves the identity are either price-change
    # forks or genuinely distinct series for one identifier. The migration
    # cannot tell them apart, so it keeps the newest row unscoped and stamps
    # the rest with their amount as a discriminator -- preserving every row and
    # the old identity semantics exactly -- and logs each group for a one-time
    # human review.
    def stamp_existing_price_forks
      rows = select_all(<<~SQL).to_a
        SELECT id, family_id, account_id, destination_account_id, merchant_id, name, currency,
               amount, updated_at
        FROM recurring_transactions
        ORDER BY updated_at DESC
      SQL

      groups = rows.group_by do |row|
        [ row["family_id"], row["account_id"], row["destination_account_id"],
          row["merchant_id"] || "name:#{row['name']}", row["currency"] ]
      end

      groups.each_value do |group|
        next if group.size == 1

        keeper, *rest = group
        say "dedup_scope: keeping #{keeper['id']} (#{keeper['amount']}) unscoped; stamping #{rest.size} sibling(s)"

        rest.each do |row|
          scope = BigDecimal(row["amount"].to_s).to_s("F")
          say "  #{row['id']} amount=#{row['amount']} -> dedup_scope=#{scope}"
          update("UPDATE recurring_transactions SET dedup_scope = #{quote(scope)} WHERE id = #{quote(row['id'])}")
        end
      end
    end
end
