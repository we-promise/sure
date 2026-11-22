# frozen_string_literal: true

# Shared reading of the account-details snapshot a Redbark sync stored.
class RedbarkAccount::DetailsProcessor
  attr_reader :redbark_account, :as_of

  def initialize(redbark_account, as_of:)
    @redbark_account = redbark_account
    @as_of = as_of
  end

  private
    # A payload the sync did not refresh is a previous answer, not a current
    # one. Acting on it can record a change that never happened: the fetch
    # fails, the stored snapshot still holds last week's rate, the user has
    # since corrected the account by hand, and the stale figure is written back
    # over their correction as though the bank had just reported it.
    #
    # Keyed to the sync's own date rather than to a duration, because `as_of`
    # is the only notion of "now" this class is allowed. RedbarkItem::Syncer
    # reads the clock ONCE and hands the same instant to the import that writes
    # this stamp and to the processing that supplies `as_of`, so the comparison
    # below is a clock against itself; two readings would make a sync that
    # crosses midnight reject the snapshot it had just stored. A second sync on
    # the same day after a failed fetch re-reads a snapshot that was fresh this
    # morning, which is harmless: the rate has not moved, so nothing is
    # recorded.
    def details_fetched_this_sync?
      fetched_at = redbark_account.account_details_fetched_at
      return false if fetched_at.blank?

      # In the family's zone, as the syncer derives `as_of`; the stamp itself
      # reads back in the app's zone.
      redbark_account.redbark_item.family.local_date(fetched_at) == as_of.to_date
    end

    def account
      @account ||= redbark_account.current_account
    end

    def details
      @details ||= redbark_account.raw_account_details_payload&.deep_symbolize_keys || {}
    end

    def capture(message, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "redbark",
        family: redbark_account.redbark_item&.family,
        metadata: metadata.merge(redbark_account_id: redbark_account.id)
      )
    end
end
