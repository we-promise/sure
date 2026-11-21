# Only the user who opened an import session, or an admin, may add to or
# publish it. Sessions from before this are admin-only (null).
class AddCreatedByToImportSessions < ActiveRecord::Migration[8.1]
  def change
    add_reference :import_sessions, :created_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
  end
end
