class CreateArchivedExports < ActiveRecord::Migration[7.2]
  def change
    create_table :archived_exports, id: :uuid do |t|
      t.string :email, null: false
      t.string :family_name
      t.string :download_token_digest, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :archived_exports, :download_token_digest, unique: true
    add_index :archived_exports, :expires_at
  end
end
