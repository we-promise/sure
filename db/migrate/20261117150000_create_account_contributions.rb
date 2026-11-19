class CreateAccountContributions < ActiveRecord::Migration[8.1]
  def change
    create_table :account_contributions, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :account_statement, type: :uuid, foreign_key: { on_delete: :nullify }
      t.date :date, null: false
      # Signed: positive is money put into the account, negative is money taken out.
      t.decimal :amount, precision: 19, scale: 4, null: false
      # The part of a transfer that counts as principal (e.g. a rollover's cost
      # basis). Nil means the whole amount.
      t.decimal :principal_amount, precision: 19, scale: 4
      t.string :currency, limit: 3, null: false
      t.string :kind, null: false, default: "contribution"
      t.string :description, limit: 255
      t.string :source, null: false, default: "manual"
      t.boolean :estimated, null: false, default: false
      t.timestamps
    end

    add_index :account_contributions, [ :account_id, :date ]
  end
end
