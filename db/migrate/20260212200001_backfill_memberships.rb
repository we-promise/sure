class BackfillMemberships < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      INSERT INTO memberships (id, user_id, family_id, role, created_at, updated_at)
      SELECT gen_random_uuid(), id, family_id, role, NOW(), NOW()
      FROM users
      WHERE family_id IS NOT NULL
      ON CONFLICT (user_id, family_id) DO NOTHING
    SQL
  end

  def down
    execute "DELETE FROM memberships"
  end
end
