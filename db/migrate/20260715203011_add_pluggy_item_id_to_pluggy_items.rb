# frozen_string_literal: true

class AddPluggyItemIdToPluggyItems < ActiveRecord::Migration[7.2]
  def change
    add_column :pluggy_items, :pluggy_item_id, :string
    add_index :pluggy_items, :pluggy_item_id
  end
end
