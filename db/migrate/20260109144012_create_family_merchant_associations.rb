class CreateFamilyMerchantAssociations < ActiveRecord::Migration[7.2]
  def change
    create_table :family_merchant_associations, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :merchant, null: false, foreign_key: true, type: :uuid
      t.datetime :unlinked_at

      t.timestamps
    end

    add_index :family_merchant_associations, [ :family_id, :merchant_id ], unique: true
  end
end
