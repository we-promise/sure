class AddCustomGroupIndexToAccounts < ActiveRecord::Migration[8.1]
  def change
    # Backs the account form's custom group suggestions, which read the
    # distinct non-null values per family.
    add_index :accounts, [ :family_id, :custom_group ],
      where: "custom_group IS NOT NULL",
      name: "index_accounts_on_family_id_and_custom_group"
  end
end
