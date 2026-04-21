class AddAdminRoleToCurrentUsers < ActiveRecord::Migration[7.2]
  def up
    execute "UPDATE users SET role = 'admin'"
  end
end
