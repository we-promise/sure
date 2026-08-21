class AddLastLoginAtAndSessionsCountToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :last_login_at, :datetime, if_not_exists: true
    add_column :users, :sessions_count, :integer, default: 0, null: false, if_not_exists: true

    # Backfill existing data from sessions table
    reversible do |dir|
      dir.up do
        say_with_time "Backfilling last_login_at and sessions_count" do
          User.find_each do |user|
            last_login = Session.where(user_id: user.id).maximum(:created_at)
            session_cnt = Session.where(user_id: user.id).count
            user.update_columns(last_login_at: last_login, sessions_count: session_cnt)
          end
        end
      end
    end
  end
end
