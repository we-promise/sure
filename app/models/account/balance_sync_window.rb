# frozen_string_literal: true

# Resolves the earliest date from which an account balance sync should recalculate
# when no explicit window was passed on the parent sync.
class Account::BalanceSyncWindow
  LOOKBACK = 7.days

  class << self
    # @param account [Account]
    # @param parent_sync [Sync, nil] Used to detect entries created/updated during this sync run
    # @param parent_window_start_date [Date, nil] Explicit window from caller or parent sync
    # @param import_window_start_date [Date, nil] Transaction fetch window from provider import
    # @param last_synced_at [Time, nil] Provider item freshness timestamp
    # @return [Date, nil] nil means full balance recalculation
    def for_account(account, parent_sync: nil, parent_window_start_date: nil, import_window_start_date: nil, last_synced_at: nil)
      return parent_window_start_date.to_date if parent_window_start_date.present?

      candidates = []
      candidates << import_window_start_date.to_date if import_window_start_date.present?
      candidates << entries_touched_since(parent_sync, account) if parent_sync
      candidates << (last_synced_at.to_date - LOOKBACK) if last_synced_at.present?

      window = candidates.compact.min
      return nil unless window

      floor = [ account.opening_anchor_date, account.start_date ].compact.max
      [ window, floor ].max
    end

    private

      def entries_touched_since(sync, account)
        sync_started_at = sync.created_at
        return nil unless sync_started_at

        account.entries
               .where("entries.created_at >= :t OR entries.updated_at >= :t", t: sync_started_at)
               .minimum(:date)
      end
  end
end
