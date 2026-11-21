# frozen_string_literal: true

# Stored encrypted (like session_blob) so the daily login can be started
# without the user retyping the PIN. Existing items have none and keep the
# manual login.
class AddPinToTradeRepublicItems < ActiveRecord::Migration[8.1]
  def change
    add_column :trade_republic_items, :pin, :text
  end
end
