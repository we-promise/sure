class CreatePockets < ActiveRecord::Migration[7.2]
  def change
    create_table :pockets, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.string :name
      t.decimal :allocated_amount, precision: 19, scale: 4, null: false, default: "0.0"
      t.string :currency, null: false

      t.timestamps
    end

    add_check_constraint :pockets, "allocated_amount >= 0", name: "chk_pockets_allocated_amount_non_negative"
    add_check_constraint :pockets, "currency <> ''", name: "chk_pockets_currency_present"
  end
end
