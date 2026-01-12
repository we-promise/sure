class CreateInstallments < ActiveRecord::Migration[7.2]
  def change
    create_table :installments, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid, index: true
      t.decimal :installment_cost, precision: 19, scale: 4, null: false
      t.integer :total_term, null: false
      t.integer :current_term, null: false, default: 0
      t.string :payment_period, null: false
      t.date :first_payment_date, null: false
      t.date :most_recent_payment_date, null: false

      t.timestamps
    end

    add_check_constraint :installments, "current_term <= total_term", name: "current_term_lte_total_term"
    add_check_constraint :installments, "current_term >= 0", name: "current_term_gte_zero"
    add_check_constraint :installments, "total_term > 0", name: "total_term_positive"
    add_check_constraint :installments, "installment_cost > 0", name: "installment_cost_positive"
  end
end
