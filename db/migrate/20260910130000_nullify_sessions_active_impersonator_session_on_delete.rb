class NullifySessionsActiveImpersonatorSessionOnDelete < ActiveRecord::Migration[7.2]
  def up
    remove_foreign_key :sessions, :impersonation_sessions, column: :active_impersonator_session_id
    add_foreign_key :sessions, :impersonation_sessions, column: :active_impersonator_session_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :sessions, :impersonation_sessions, column: :active_impersonator_session_id
    add_foreign_key :sessions, :impersonation_sessions, column: :active_impersonator_session_id
  end
end
