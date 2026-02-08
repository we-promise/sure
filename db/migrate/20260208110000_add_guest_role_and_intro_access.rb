class AddGuestRoleAndIntroAccess < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE users
      SET role = 'member'
      WHERE role = 'user'
    SQL

    execute <<~SQL.squish
      UPDATE users
      SET role = 'guest',
          ui_layout = 'intro',
          show_sidebar = FALSE,
          show_ai_sidebar = FALSE,
          ai_enabled = TRUE
      WHERE role = 'intro'
         OR (role = 'member' AND ui_layout = 'intro')
         OR (role = 'user' AND ui_layout = 'intro')
    SQL

    execute <<~SQL.squish
      UPDATE users
      SET ui_layout = 'dashboard'
      WHERE role IN ('member', 'admin', 'super_admin')
        AND ui_layout = 'intro'
    SQL

    execute <<~SQL.squish
      UPDATE invitations
      SET role = 'member'
      WHERE role = 'user'
    SQL

    execute <<~SQL.squish
      UPDATE invitations
      SET role = 'guest'
      WHERE role = 'intro'
    SQL

    change_column_default :users, :role, "member"
  end

  def down
    execute <<~SQL.squish
      UPDATE invitations
      SET role = 'intro'
      WHERE role = 'guest'
    SQL

    execute <<~SQL.squish
      UPDATE invitations
      SET role = 'user'
      WHERE role = 'member'
    SQL

    execute <<~SQL.squish
      UPDATE users
      SET role = 'intro',
          ui_layout = 'intro',
          show_sidebar = FALSE,
          show_ai_sidebar = FALSE,
          ai_enabled = TRUE
      WHERE role = 'guest'
    SQL

    execute <<~SQL.squish
      UPDATE users
      SET role = 'user'
      WHERE role = 'member'
    SQL

    change_column_default :users, :role, "user"
  end
end
