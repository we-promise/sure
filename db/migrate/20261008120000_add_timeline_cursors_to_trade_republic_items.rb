# frozen_string_literal: true

class AddTimelineCursorsToTradeRepublicItems < ActiveRecord::Migration[8.1]
  def change
    add_column :trade_republic_items, :timeline_cursors, :jsonb, default: {}, null: false
  end
end
