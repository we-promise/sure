class CreateGiftCards < ActiveRecord::Migration[8.1]
  def change
    create_table :gift_cards, id: :uuid do |t|
      t.date :expires_on
      t.decimal :face_value, precision: 19, scale: 4
      t.string :face_value_currency
      t.string :card_format, null: false, default: "physical"
      t.text :card_number
      t.text :pin
      t.text :redeem_url
      t.string :subtype
      t.jsonb :locked_attributes, default: {}

      t.timestamps
    end

    add_check_constraint :gift_cards,
                         "card_format IN ('physical', 'digital')",
                         name: "chk_gift_cards_card_format"
  end
end
