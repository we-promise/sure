class AddAnnualFeeDateToCreditCards < ActiveRecord::Migration[8.1]
  def change
    add_column :credit_cards, :annual_fee_month, :integer
    add_column :credit_cards, :annual_fee_day, :integer
    add_check_constraint :credit_cards, "annual_fee_month >= 1 AND annual_fee_month <= 12", name: "chk_credit_cards_annual_fee_month"
    add_check_constraint :credit_cards, "annual_fee_day >= 1 AND annual_fee_day <= 31", name: "chk_credit_cards_annual_fee_day"
  end
end
