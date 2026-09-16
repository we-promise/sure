class AddFactsToInsights < ActiveRecord::Migration[7.2]
  def change
    # Display values (formatted money, localized dates) used to render key
    # figures and contextual links. Refreshed on every run — unlike
    # `metadata`, which holds only the bucketed change-detection signals.
    add_column :insights, :facts, :jsonb, null: false, default: {}
  end
end
