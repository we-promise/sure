class AddCascadeToImpersonationSessionForeignKeys < ActiveRecord::Migration[7.2]
  def change
    remove_foreign_key :impersonation_session_logs, :impersonation_sessions
    add_foreign_key :impersonation_session_logs, :impersonation_sessions, on_delete: :cascade

    remove_foreign_key :impersonation_sessions, :users, column: :impersonator_id
    remove_foreign_key :impersonation_sessions, :users, column: :impersonated_id
    add_foreign_key :impersonation_sessions, :users, column: :impersonator_id, on_delete: :cascade
    add_foreign_key :impersonation_sessions, :users, column: :impersonated_id, on_delete: :cascade
  end
end
