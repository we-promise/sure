class AddIndexOnSessionsUpdatedAt < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :sessions, :updated_at, algorithm: :concurrently, if_not_exists: true
  end
end
