class AlignPocketsSchema < ActiveRecord::Migration[7.2]
  def up
    # The pockets table was created by a prior migration that is no longer on disk.
    # Its schema used the money-rails pattern (amount_cents/amount_currency).
    # This migration aligns it with the rest of the codebase which stores
    # monetary values as decimal with a separate string currency column.
    remove_column :pockets, :amount_cents
    remove_column :pockets, :amount_currency

    add_column :pockets, :allocated_amount, :decimal, precision: 19, scale: 4, null: false, default: "0.0"
    add_column :pockets, :currency, :string, null: false, default: ""

    add_check_constraint :pockets, "allocated_amount >= 0", name: "chk_pockets_allocated_amount_non_negative"
  end

  def down
    remove_check_constraint :pockets, name: "chk_pockets_allocated_amount_non_negative"
    remove_column :pockets, :currency
    remove_column :pockets, :allocated_amount

    add_column :pockets, :amount_cents, :integer
    add_column :pockets, :amount_currency, :string
  end
end
