class AddOauthDeviceFlowToSnaptradeItems < ActiveRecord::Migration[7.2]
  def change
    add_column :snaptrade_items, :oauth_access_token, :string
    add_column :snaptrade_items, :oauth_refresh_token, :string
    add_column :snaptrade_items, :oauth_token_type, :string
    add_column :snaptrade_items, :oauth_scope, :string
    add_column :snaptrade_items, :oauth_token_expires_at, :datetime
  end
end
