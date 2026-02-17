class AddAssistantTypeToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :assistant_type, :string, default: "builtin", null: false
  end
end
