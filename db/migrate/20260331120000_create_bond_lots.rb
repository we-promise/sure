class CreateBondLots < ActiveRecord::Migration[7.2]
  def change
    create_table :bond_lots, id: :uuid do |t|
      t.references :bond, null: false, foreign_key: true, type: :uuid
      t.date :purchased_on, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.integer :term_months, null: false
      t.date :maturity_date, null: false
      t.decimal :interest_rate, precision: 10, scale: 3

      t.timestamps
    end

    add_index :bond_lots, [ :bond_id, :purchased_on ]

    # Database-level constraints for domain invariants
    add_check_constraint :bond_lots, "amount > 0", name: "check_bond_lots_positive_amount"
    add_check_constraint :bond_lots, "term_months > 0", name: "check_bond_lots_positive_term"
    add_check_constraint :bond_lots, "maturity_date >= purchased_on", name: "check_bond_lots_maturity_after_purchase"
  end
end
