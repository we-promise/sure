class CreateInstallments < ActiveRecord::Migration[7.2]
  def change
    create_table :installments, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.integer :total_installments
      t.string :payment_period
      t.date :first_payment_date
      t.integer :installment_cost_cents
      t.string :currency
      t.boolean :auto_generate, default: false

      t.timestamps
    end

    add_reference :transactions, :installment, type: :uuid, foreign_key: true, null: true
  end
end
