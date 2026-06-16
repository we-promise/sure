class CreateBrazilBanks < ActiveRecord::Migration[7.2]
  def change
    create_table :brazil_banks, id: :uuid do |t|
      t.string :ispb, null: false
      t.string :code
      t.string :name, null: false
      t.string :short_name, null: false
      t.boolean :participates_in_compe, null: false, default: false
      t.string :access_kind
      t.date :started_on
      t.string :source
      t.date :source_updated_on
      t.string :logo_key
      t.string :logo_path
      t.string :logo_source_url
      t.boolean :display_in_account_selector, null: false, default: true
      t.text :searchable_text, null: false, default: ""

      t.timestamps
    end

    add_index :brazil_banks, :ispb, unique: true
    add_index :brazil_banks, :code, unique: true, where: "code IS NOT NULL AND lower(code) <> 'n/a'"
    add_index :brazil_banks, :display_in_account_selector
  end
end
