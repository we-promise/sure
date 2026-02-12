class AddFamilyIdToSessions < ActiveRecord::Migration[7.2]
  def up
    add_reference :sessions, :family, foreign_key: true, type: :uuid, null: true

    execute <<~SQL
      UPDATE sessions
      SET family_id = users.family_id
      FROM users
      WHERE sessions.user_id = users.id
    SQL
  end

  def down
    remove_reference :sessions, :family
  end
end
