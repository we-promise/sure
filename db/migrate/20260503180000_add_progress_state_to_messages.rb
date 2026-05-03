class AddProgressStateToMessages < ActiveRecord::Migration[7.2]
  def change
    add_column :messages, :progress_state, :string
  end
end
