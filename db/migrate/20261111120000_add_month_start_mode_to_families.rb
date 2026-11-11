class AddMonthStartModeToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :month_start_mode, :string, null: false, default: "fixed_day"
    add_check_constraint :families, "month_start_mode IN ('fixed_day', 'income')", name: "month_start_mode_values"

    add_reference :families, :month_start_recurring_transaction,
                  type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :recurring_transactions, on_delete: :nullify }
  end
end
