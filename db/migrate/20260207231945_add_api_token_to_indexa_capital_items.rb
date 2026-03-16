class AddApiTokenToIndexaCapitalItems < ActiveRecord::Migration[7.2]
  def change
    add_column :indexa_capital_items, :api_token, :text
  end
end
