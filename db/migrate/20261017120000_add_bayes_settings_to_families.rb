class AddBayesSettingsToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :bayes_settings, :jsonb, default: {}, null: false
  end
end
