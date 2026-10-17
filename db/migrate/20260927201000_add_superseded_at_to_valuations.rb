class AddSupersededAtToValuations < ActiveRecord::Migration[8.1]
  def change
    add_column :valuations, :superseded_at, :datetime
  end
end
