class ChangePostalCodeToStringInAddresses < ActiveRecord::Migration[7.2]
  def up
    change_column :addresses, :postal_code, :string, using: "postal_code::text"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "postal_code was changed from integer to string; alphanumeric values cannot be cast back to integer"
  end
end
