class AddAssistantTypeToFamilies < ActiveRecord::Migration[7.2]
  def up
    return if column_exists?(:families, :assistant_type)

    add_column :families, :assistant_type, :string, null: false, default: "builtin"
  end

  def down
    remove_column :families, :assistant_type, :string if column_exists?(:families, :assistant_type)
  end
end
