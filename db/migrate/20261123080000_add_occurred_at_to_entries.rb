class AddOccurredAtToEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :occurred_at, :datetime
  end
end
