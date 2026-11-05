# Marks a transaction entry as seen by one user. Together with
# User#transactions_read_before this drives the unread dot in transaction lists:
# a synced or imported transaction is unread for a user when it was created
# after their watermark and has no row here.
class EntryRead < ApplicationRecord
  belongs_to :user
  belongs_to :entry

  # Idempotent bulk insert; rows that already exist are skipped by the unique
  # (user_id, entry_id) index instead of raising.
  def self.mark!(user:, entry_ids:)
    entry_ids = Array(entry_ids).compact.uniq
    return if entry_ids.empty?

    now = Time.current
    insert_all(
      entry_ids.map { |entry_id| { user_id: user.id, entry_id: entry_id, created_at: now } },
      unique_by: %i[user_id entry_id]
    )
  end
end
