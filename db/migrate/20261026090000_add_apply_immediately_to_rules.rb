# frozen_string_literal: true

class AddApplyImmediatelyToRules < ActiveRecord::Migration[8.1]
  def change
    add_column :rules, :apply_immediately, :boolean, null: false, default: false
  end
end
