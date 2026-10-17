# frozen_string_literal: true

class WiseAccount::Processor
  attr_reader :wise_account, :import_complete, :coverage_upgraded

  # import_complete, coverage_upgraded: see WiseItem#process_accounts.
  # Processing an account on its own leaves them false, so nothing is
  # deleted or rewritten.
  def initialize(wise_account, import_complete: false, coverage_upgraded: false)
    @wise_account = wise_account
    @import_complete = import_complete
    @coverage_upgraded = coverage_upgraded
  end

  def process
    wise_account.with_processing_lock do
      # The payload a sync stored while this run waited for the lock.
      wise_account.reload

      unless wise_account.current_account.present?
        Rails.logger.info "WiseAccount::Processor - No linked account for wise_account #{wise_account.id}, skipping"
        next
      end

      process_account!
      result = process_transactions
      repair_opening_anchor
      result
    end
  rescue StandardError => e
    Rails.logger.error "WiseAccount::Processor - Failed to process account #{wise_account.id}: #{e.message}"
    Sentry.capture_exception(e) { |s| s.set_tags(wise_account_id: wise_account.id) }
    raise
  end

  private

    def process_account!
      account = wise_account.current_account
      balance = wise_account.current_balance || 0

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: wise_account.currency
      )
      follow_current_anchor(account, balance)
    end

    # The balance is set as is, with no current anchor: set_current_balance
    # would turn each day's anchor into a reconciliation, and a card payment
    # Wise completes after a sync, dated on or before that day, would then
    # shift every earlier day for good. An account linked from another
    # provider can still hold that provider's current anchor, which the
    # balance history would start from (frozen at its date and amount), so it
    # follows the live balance in place, never rotated. Never raises.
    def follow_current_anchor(account, balance)
      anchor = account.valuations.current_anchor.includes(:entry).first&.entry
      return unless anchor

      anchor.update!(amount: balance, currency: account.currency, date: Time.current.in_time_zone(wise_account.wise_item.time_zone).to_date)
    rescue StandardError => e
      capture_debug_log(
        category: "provider_sync_error",
        level: "warn",
        message: "WiseAccount::Processor - Could not move the current balance anchor to the Wise balance (#{e.class})",
        operation: "current_anchor",
        error_class: e.class.name
      )
    end

    def process_transactions
      WiseAccount::Transactions::Processor.new(
        wise_account, import_complete: import_complete, coverage_upgraded: coverage_upgraded
      ).process
    rescue StandardError => e
      Rails.logger.error "WiseAccount::Processor - Failed to process transactions for wise_account #{wise_account.id}: #{e.message}"
      Rails.logger.error Array(e.backtrace).first(10).join("\n")
      Sentry.capture_exception(e) { |s| s.set_tags(wise_account_id: wise_account.id) }
    end

    # A balance whose whole history Sure has imported was 0 the day before
    # Wise opened it (WiseAccount#opening_date), so its opening anchor (made
    # at the live balance, two years back, when the account was created) is
    # moved there, or to the day before an entry booked even earlier. Only
    # after a complete import whose coverage reaches the balance's creation,
    # for an anchor Sure set (#set_by_sure?), on an account holding nothing
    # but Wise transactions. Never raises.
    def repair_opening_anchor
      return unless import_complete

      account = wise_account.current_account
      opening_date = wise_account.opening_date
      return unless opening_date && covered_since?(wise_account.creation_time)

      anchor = account.valuations.opening_anchor.includes(:entry).first&.entry
      return if anchor.nil?
      return if account.entries.where(entryable_type: "Transaction").where("entries.source IS DISTINCT FROM ?", "wise").exists?

      manager = Account::OpeningBalanceManager.new(account)
      date = [ opening_date, manager.oldest_entry_date&.prev_day ].compact.min
      return if anchor.date == date && anchor.amount.zero?

      unless set_by_sure?(anchor)
        capture_debug_log(
          category: "provider_sync",
          level: "info",
          message: "WiseAccount::Processor - Kept an opening balance Sure does not recognise as its own, although the Wise history starts at 0 on another day",
          operation: "opening_anchor",
          opening_date: date.iso8601,
          kept_opening_date: anchor.date.iso8601
        )
        return
      end

      previous_date = anchor.date
      result = manager.set_opening_balance(balance: 0, date: date)
      wise_account.remember_opening_anchor!(anchor.reload) if result.changes_made?
      if result.error
        capture_debug_log(
          category: "provider_sync_error",
          level: "warn",
          message: "WiseAccount::Processor - Could not move the opening balance to 0 on the day before Wise opened the balance: #{result.error}",
          operation: "opening_anchor",
          opening_date: date.iso8601
        )
      elsif result.changes_made?
        capture_debug_log(
          category: "provider_sync",
          level: "info",
          message: "WiseAccount::Processor - Moved the opening balance to 0 on the day before Wise opened the balance",
          operation: "opening_anchor",
          previous_opening_date: previous_date.iso8601,
          opening_date: date.iso8601
        )
      end
    rescue StandardError => e
      capture_debug_log(
        category: "provider_sync_error",
        level: "error",
        message: "WiseAccount::Processor - Opening balance repair failed (#{e.class})",
        operation: "opening_anchor",
        error_class: e.class.name
      )
    end

    # An opening anchor is Sure's to move when it is as Sure last set it
    # (WiseAccount#written_opening_anchor) or, on an account Sure never set
    # one for, still the default made with the account (#default_anchor?).
    # One a person changed is theirs: the valuation drawer saves an edit
    # without marking it user_modified.
    def set_by_sure?(anchor)
      return false if anchor.user_modified?

      written = wise_account.written_opening_anchor
      return written[:date] == anchor.date && written[:amount] == anchor.amount if written && written[:entry_id] == anchor.id

      default_anchor?(anchor)
    end

    # The default opening anchor: the balance two years back, never changed
    # since. It was dated in the zone of the request that created the
    # account, which neither the zone this sync runs in nor the family's
    # zone now need be, so its date is within a day of the UTC date two
    # years before its creation (zones run from UTC-12 to UTC+14).
    def default_anchor?(anchor)
      (anchor.updated_at - anchor.created_at).abs < 1.second &&
        ((anchor.created_at.utc - 2.years).to_date - anchor.date).abs <= 1
    end

    # Both transfers and activities were fetched back to `time`.
    def covered_since?(time)
      return false unless time

      %i[transfers activities].all? do |source|
        coverage = wise_account.wise_item.fetch_coverage(source)
        coverage.present? && coverage[:from] <= time
      end
    end

    def capture_debug_log(category:, level:, message:, **metadata)
      DebugLogEntry.capture(
        category: category,
        level: level,
        message: message,
        source: self.class.name,
        provider_key: "wise",
        family: wise_account.wise_item.family,
        account_provider: wise_account.account_provider,
        metadata: { wise_item_id: wise_account.wise_item_id, wise_account_id: wise_account.id, currency: wise_account.currency }.merge(metadata)
      )
    rescue StandardError => e
      Rails.logger.warn "WiseAccount::Processor - Failed to capture Wise debug log: #{e.message}"
    end
end
