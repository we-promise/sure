# frozen_string_literal: true

class RestoreTradeCategoryReference < ActiveRecord::Migration[7.2]
  def up
    return if column_exists?(:trades, :category_id)

    add_reference :trades, :category, null: true, foreign_key: true, type: :uuid
  end

  def down
    return unless column_exists?(:trades, :category_id)

    remove_reference :trades, :category, foreign_key: true, type: :uuid
  end
end
