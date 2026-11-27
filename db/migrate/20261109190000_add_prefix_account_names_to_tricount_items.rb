# frozen_string_literal: true

class AddPrefixAccountNamesToTricountItems < ActiveRecord::Migration[8.1]
  def change
    # Whether accounts created for this connection's tricounts are named
    # "Tricount: <title>" rather than the tricount's title alone.
    add_column :tricount_items, :prefix_account_names, :boolean, default: false, null: false
  end
end
