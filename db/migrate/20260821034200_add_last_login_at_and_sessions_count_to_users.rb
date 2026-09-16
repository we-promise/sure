class AddLastLoginAtAndSessionsCountToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :last_login_at, :datetime, if_not_exists: true
    add_column :users, :sessions_count, :integer, default: 0, null: false, if_not_exists: true

    # Backfill existing data from sessions table
    reversible do |dir|
      dir.up do
        say_with_time "Backfilling last_login_at and sessions_count" do
          execute <<-SQL
            UPDATE users
            SET last_login_at = (SELECT MAX(created_at) FROM sessions WHERE user_id = users.id),
                sessions_count = (SELECT COUNT(*) FROM sessions WHERE user_id = users.id);
          SQL
        end
      end
    end
  end
end
