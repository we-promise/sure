# Minimal dedup record for WeeklyCleanupJob: one row per admin per weekly
# period. Its existence means "this admin already got the proactive cleanup
# chat for that week" — reruns of the job skip without respawning a chat.
# The generated findings themselves live in the chat message; this table only
# carries enough metadata to make reruns and debugging cheap.
class WeeklyCleanupRun < ApplicationRecord
  belongs_to :family
  belongs_to :user

  validates :period_start, presence: true
  validates :period_start, uniqueness: { scope: [ :family_id, :user_id ] }

  def self.period_for(date = Date.current)
    date.beginning_of_week
  end
end
