class AddGoCardlessTokenFields < ActiveRecord::Migration[7.2]
  def change
    add_column :gocardless_items, :requisition_id,          :string
    add_column :gocardless_items, :agreement_id,            :string
    add_column :gocardless_items, :access_token,            :text
    add_column :gocardless_items, :refresh_token,           :text
    add_column :gocardless_items, :access_token_expires_at, :datetime
  end
end
