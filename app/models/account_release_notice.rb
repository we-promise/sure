# One e-mail release reminder sent to one person. The unique
# index on (account, user, kind, release date) keeps the daily job from
# mailing the same reminder twice, even when two runs overlap.
class AccountReleaseNotice < ApplicationRecord
  belongs_to :account
  belongs_to :user

  validates :kind, inclusion: { in: Account::ReleaseReminder::KINDS }

  # Records the reminders in one insert_all and returns only those this call
  # actually inserted; rows another run already wrote are skipped by the
  # unique index, so concurrent runs each get a disjoint set back.
  def self.record_for(user:, reminders:)
    return [] if reminders.empty?

    now = Time.current
    rows = reminders.map do |reminder|
      { account_id: reminder.account.id, user_id: user.id, kind: reminder.kind,
        release_on: reminder.release_on, created_at: now, updated_at: now }
    end

    inserted = insert_all(rows, unique_by: :index_account_release_notices_uniqueness,
                                returning: %i[account_id kind release_on])
                 .rows.map { |account_id, kind, release_on| [ account_id, kind, release_on.to_date ] }
                 .to_set

    reminders.select { |reminder| inserted.include?([ reminder.account.id, reminder.kind, reminder.release_on ]) }
  end

  # Undoes record_for when the e-mail could not be sent.
  def self.forget(user:, reminders:)
    reminders.each do |reminder|
      where(account_id: reminder.account.id, user_id: user.id, kind: reminder.kind, release_on: reminder.release_on).delete_all
    end
  end
end
