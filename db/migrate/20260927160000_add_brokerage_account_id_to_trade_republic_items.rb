# duplicate_connection? only checked trade_republic_accounts, which the
# importer creates on first sync -- not at login. Two logins for the same
# broker account (concurrently, or sequentially before the first item's
# sync_later job has run) could both pass that check. Storing the account id
# on the item itself as soon as login succeeds, backed by this unique index,
# closes that window: the second write raises RecordNotUnique instead of
# silently creating a second item for the same account.
class AddBrokerageAccountIdToTradeRepublicItems < ActiveRecord::Migration[8.1]
  def change
    add_column :trade_republic_items, :brokerage_account_id, :string
    add_index :trade_republic_items, [ :family_id, :brokerage_account_id ],
      unique: true,
      where: "(brokerage_account_id IS NOT NULL) AND (scheduled_for_deletion = false)",
      name: "index_trade_republic_items_on_family_id_and_brokerage_account"
  end
end
