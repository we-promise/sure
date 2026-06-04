class CreateFamilyMemberships < ActiveRecord::Migration[7.2]
  def up
    create_table :family_memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :family, null: false, foreign_key: true, type: :uuid

      t.timestamps
    end

    add_index :family_memberships, [ :user_id, :family_id ], unique: true

    execute <<~SQL.squish
      INSERT INTO family_memberships (id, user_id, family_id, created_at, updated_at)
      SELECT gen_random_uuid(), users.id, users.family_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM users
      WHERE users.family_id IS NOT NULL
      ON CONFLICT (user_id, family_id) DO NOTHING
    SQL
  end

  def down
    drop_table :family_memberships
  end
end
