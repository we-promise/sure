class CreateRuleGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :rule_groups, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    add_index :rule_groups, [ :family_id, :name ], unique: true

    add_reference :rules, :rule_group, type: :uuid, foreign_key: { on_delete: :nullify }

    # The group column of a rule CSV import
    add_column :import_rows, :rule_group, :string
  end
end
