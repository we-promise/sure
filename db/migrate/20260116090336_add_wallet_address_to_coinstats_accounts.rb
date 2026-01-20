class AddWalletAddressToCoinstatsAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :coinstats_accounts, :wallet_address, :string

    # Supprimer l'ancien index simple sur account_id
    remove_index :coinstats_accounts,
                 name: "index_coinstats_accounts_on_account_id",
                 if_exists: true

    # Créer le nouvel index composite unique
    add_index :coinstats_accounts,
              [ :coinstats_item_id, :account_id, :wallet_address ],
              unique: true,
              name: "index_coinstats_accounts_on_item_account_and_wallet"
  end
end
