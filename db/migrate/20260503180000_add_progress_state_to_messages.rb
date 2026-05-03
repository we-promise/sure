class AddProgressStateToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :progress_state, :string
  end
end
