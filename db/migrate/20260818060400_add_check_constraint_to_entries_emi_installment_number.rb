class AddCheckConstraintToEntriesEmiInstallmentNumber < ActiveRecord::Migration[7.2]
  def change
    # Belt-and-suspenders alongside the app-level amortization logic, which
    # only ever assigns positive numbers by construction: this closes off
    # zero/negative values at the schema level too, matching the reasoning
    # for the unique (emi_plan_id, emi_installment_number) index added in
    # 20260817000000_add_unique_index_to_entries_on_emi_plan_and_installment_number.rb.
    add_check_constraint :entries,
      "emi_installment_number IS NULL OR emi_installment_number > 0",
      name: "chk_entries_emi_installment_number_positive"
  end
end
