class AddMonthStartDayToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :month_start_day, :integer, default: 1, null: false
    add_check_constraint :families, "month_start_day >= 1 AND month_start_day <= 28", name: "month_start_day_range"
  end
end
