class CreateEnvelopes < ActiveRecord::Migration[7.2]
  def change
    create_table :envelopes, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :category, foreign_key: { on_delete: :nullify }, type: :uuid, index: false
      t.string :name, null: false
      t.decimal :monthly_contribution, precision: 19, scale: 4, null: false, default: 0
      t.string :currency, null: false
      t.decimal :target_amount, precision: 19, scale: 4
      t.date :target_date
      t.date :starts_on, null: false
      t.string :color
      t.string :icon
      t.text :notes

      t.timestamps
    end

    add_index :envelopes, :category_id,
              unique: true,
              where: "category_id IS NOT NULL",
              name: "index_envelopes_on_category_unique"

    add_check_constraint :envelopes, "char_length(name) <= 255", name: "chk_envelopes_name_length"
    add_check_constraint :envelopes, "monthly_contribution >= 0", name: "chk_envelopes_monthly_contribution_non_negative"
    add_check_constraint :envelopes,
                         "target_amount IS NULL OR target_amount > 0",
                         name: "chk_envelopes_target_amount_positive"
    add_check_constraint :envelopes,
                         "target_date IS NULL OR target_amount IS NOT NULL",
                         name: "chk_envelopes_target_date_requires_target_amount"
  end
end
