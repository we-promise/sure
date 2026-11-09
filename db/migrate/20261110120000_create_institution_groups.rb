class CreateInstitutionGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :institution_groups, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :key, null: false
      t.string :name
      t.string :institution_domain
      t.string :currency
      # The group's own icon (an attached logo) shows Brandfetch's instead, as an account's can.
      t.string :logo_selection, null: false, default: "automatic"

      t.timestamps
    end

    add_index :institution_groups, [ :family_id, :key ], unique: true
  end
end
