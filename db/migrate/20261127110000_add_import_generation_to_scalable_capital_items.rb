class AddImportGenerationToScalableCapitalItems < ActiveRecord::Migration[8.1]
  def change
    add_column :scalable_capital_items, :import_generation, :bigint, default: 0, null: false
  end
end
