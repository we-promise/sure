class CreatePockets < ActiveRecord::Migration[7.2]
  def up
    return if table_exists?(:pockets)

    create_table :pockets, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.string :name
      t.integer :amount_cents
      t.string :amount_currency

      t.timestamps
    end
  end

  def down
    drop_table :pockets, if_exists: true
  end
end
