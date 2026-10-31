# Nightly retry for accounts whose domain has no logo yet: new accounts whose
# first fetch failed, and accounts that had a domain before auto-fetching existed.
class AccountLogoBackfillJob < ApplicationJob
  queue_as :scheduled

  # The iTunes Search API allows about 20 requests a minute, and each fetch
  # makes up to three of them.
  SPACING = 20.seconds
  # Spread over about 17 hours, so a run is done before the next one starts.
  # Larger backlogs continue from a cursor the next night.
  BATCH_SIZE = 3_000
  CURSOR_KEY = "account_logo_backfill_cursor"

  def perform(batch_size: BATCH_SIZE)
    cursor = Rails.cache.read(CURSOR_KEY)
    batch = accounts.where(cursor ? [ "accounts.id > ?", cursor ] : nil).limit(batch_size).to_a
    batch = accounts.limit(batch_size).to_a if batch.empty? && cursor

    Rails.cache.write(CURSOR_KEY, (batch.last.id if batch.size == batch_size))
    batch.each { |account| AccountLogoFetchJob.perform_paced(account) }
  end

  private
    def accounts
      Account.visible
        .where.not(institution_domain: [ nil, "" ])
        .logo_automatic
        .where.missing(:logo_attachment)
        .order(:id)
    end
end
