class AddTokenColumnsToGocardlessItems < ActiveRecord::Migration[7.2]
  def change
    add_column :gocardless_items, :requisition_id,          :string,   if_not_exists: true
    add_column :gocardless_items, :agreement_id,            :string,   if_not_exists: true
    add_column :gocardless_items, :agreement_expires_at,    :datetime, if_not_exists: true
    add_column :gocardless_items, :access_token,            :text,     if_not_exists: true
    add_column :gocardless_items, :refresh_token,           :text,     if_not_exists: true
    add_column :gocardless_items, :access_token_expires_at, :datetime, if_not_exists: true

    add_index :gocardless_items, :requisition_id, if_not_exists: true
  end
end
