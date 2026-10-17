class CreateEmiPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :emi_plans, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entry_id, null: false # the original purchase entry (parent)
      t.uuid :account_id, null: false
      t.decimal :principal_amount, precision: 19, scale: 4, null: false
      t.decimal :interest_rate, precision: 10, scale: 3, null: false, default: 0 # annual %, 0 = no-cost EMI
      t.integer :tenure_months, null: false
      t.decimal :processing_fee, precision: 19, scale: 4, null: false, default: 0
      t.date :start_date, null: false # date of the 1st installment
      t.string :status, null: false, default: "active" # active | foreclosed | completed

      # Records the Transaction#kind the parent entry had immediately before
      # conversion to an EMI plan (always "standard" going forward, since
      # emi_convertible? now requires that -- see Transaction::Splittable).
      # EmiPlan#build! writes it, and EmiPlan#foreclose! reads it back to
      # restore the exact original kind instead of hard-coding "standard",
      # so a plan built on a not-yet-"standard" historical row (from before
      # this constraint existed) still unwinds correctly on foreclosure.
      t.string :original_kind, null: false, default: "standard"

      t.uuid :processing_fee_entry_id # one-time fee entry, if a fee was charged
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index :entry_id, unique: true
      t.index :account_id
      t.index :status
    end

    add_foreign_key :emi_plans, :entries, column: :entry_id, on_delete: :cascade
    add_foreign_key :emi_plans, :accounts, column: :account_id, on_delete: :cascade
    add_foreign_key :emi_plans, :entries, column: :processing_fee_entry_id, on_delete: :nullify

    # Each generated installment entry points back to its plan + its position (1-indexed).
    add_column :entries, :emi_plan_id, :uuid
    add_column :entries, :emi_installment_number, :integer

    add_index :entries, :emi_plan_id

    # Guards against two installment entries ever sharing the same position
    # within a plan (e.g. a bug or unexpected retry in EmiPlan#build! double-
    # creating installment #3). The app currently only creates each number
    # once by construction, but that's an app-level guarantee, not a DB one --
    # this makes it one at the schema level too, matching the same reasoning
    # as the unique index on emi_plans.entry_id.
    #
    # Partial index (WHERE emi_plan_id IS NOT NULL): most entries have a NULL
    # emi_plan_id (they aren't installments at all), and NULLs are already
    # distinct from each other under a standard unique index in Postgres, but
    # scoping it explicitly keeps the index small and its intent clear.
    add_index :entries, [ :emi_plan_id, :emi_installment_number ],
              unique: true,
              where: "emi_plan_id IS NOT NULL",
              name: "index_entries_on_emi_plan_id_and_installment_number"

    # NB: on_delete is intentionally :nullify, not :cascade. An EmiPlan can be
    # foreclosed/destroyed while some of its installment entries have already
    # posted (real money movement) — those must survive as ordinary entries,
    # matching Entry#originated_emi_plan's dependent: :destroy on the *plan*
    # itself but EmiPlan#installment_entries' dependent: :nullify on its
    # children. Cascading a hard delete here would silently erase spend
    # history the app deliberately protects (see EmiPlan#foreclose!).
    add_foreign_key :entries, :emi_plans, column: :emi_plan_id, on_delete: :nullify

    add_check_constraint :emi_plans, "tenure_months > 0 AND tenure_months <= 480", name: "chk_emi_plans_tenure_months_range"
    add_check_constraint :emi_plans, "principal_amount > 0", name: "chk_emi_plans_principal_amount_positive"
    add_check_constraint :emi_plans, "interest_rate >= 0 AND interest_rate <= 100", name: "chk_emi_plans_interest_rate_range"
    add_check_constraint :emi_plans, "processing_fee >= 0", name: "chk_emi_plans_processing_fee_non_negative"
    add_check_constraint :emi_plans, "status IN ('active', 'foreclosed', 'completed')", name: "chk_emi_plans_status"

    # Belt-and-suspenders alongside the app-level amortization logic, which
    # only ever assigns positive numbers by construction: this closes off
    # zero/negative values at the schema level too, matching the reasoning
    # for the unique (emi_plan_id, emi_installment_number) index above.
    add_check_constraint :entries,
      "emi_installment_number IS NULL OR emi_installment_number > 0",
      name: "chk_entries_emi_installment_number_positive"
  end
end
