class AddClassificationFetchedAtToSecurities < ActiveRecord::Migration[8.1]
  # When the price provider was last asked for a classification and answered,
  # whether or not the answer held anything. Nil means never asked.
  def change
    add_column :securities, :classification_fetched_at, :datetime
  end
end
