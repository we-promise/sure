class AddFiscalYearStartToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :fiscal_year_start_month, :integer, default: 1, null: false
    add_column :families, :fiscal_year_start_day, :integer, default: 1, null: false

    add_check_constraint :families,
      "fiscal_year_start_month >= 1 AND fiscal_year_start_month <= 12",
      name: "fiscal_year_start_month_range"

    add_check_constraint :families,
      "fiscal_year_start_day >= 1 AND fiscal_year_start_day <= 28",
      name: "fiscal_year_start_day_range"
  end
end
