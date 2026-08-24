class RemoveTradeRepublicLocale < ActiveRecord::Migration[7.2]
  def change
    remove_column :trade_republic_items, :locale, :string if column_exists?(:trade_republic_items, :locale)
  end
end
