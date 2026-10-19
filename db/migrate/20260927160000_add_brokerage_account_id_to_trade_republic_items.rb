# trade_republic_accounts only exist after the first sync, so the account id is
# stored on the item at login; this index makes a second active login for the
# same account raise RecordNotUnique.
class AddBrokerageAccountIdToTradeRepublicItems < ActiveRecord::Migration[8.1]
  def change
    add_column :trade_republic_items, :brokerage_account_id, :string
    add_index :trade_republic_items, [ :family_id, :brokerage_account_id ],
      unique: true,
      where: "(brokerage_account_id IS NOT NULL) AND (scheduled_for_deletion = false)",
      name: "index_trade_republic_items_on_family_id_and_brokerage_account"
  end
end
