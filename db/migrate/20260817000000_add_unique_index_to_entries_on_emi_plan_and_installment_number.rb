class AddUniqueIndexToEntriesOnEmiPlanAndInstallmentNumber < ActiveRecord::Migration[7.2]
  def change
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
  end
end
