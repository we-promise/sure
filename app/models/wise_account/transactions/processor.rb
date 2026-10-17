# frozen_string_literal: true

class WiseAccount::Transactions::Processor
  # A sync that would delete more stale entries than this (at least
  # PRUNE_CAP_MINIMUM, or PRUNE_CAP_SHARE of the account's Wise entries)
  # deletes none: that many at once looks like a fault, not a correction.
  PRUNE_CAP_MINIMUM = 5
  PRUNE_CAP_SHARE = BigDecimal("0.1")

  # The entries of the rows routing moves between balances (transfers and
  # activities; statement rows never move). With no row to date an empty
  # payload by, only these can be stale on it.
  ROUTED_EXTERNAL_ID_PREFIXES = %w[wise_transfer_ wise_fee_ wise_refund_ wise_interbalance_ wise_activity_].freeze
  MAX_LOGGED_EXTERNAL_IDS = 20

  attr_reader :wise_account, :import_complete, :coverage_upgraded

  # import_complete, coverage_upgraded: see WiseItem#process_accounts.
  def initialize(wise_account, import_complete: false, coverage_upgraded: false)
    @wise_account = wise_account
    @import_complete = import_complete
    @coverage_upgraded = coverage_upgraded
  end

  def process
    payload = wise_account.raw_transactions_payload
    rows = Array(payload)
    total = rows.count
    if rows.empty?
      Rails.logger.info "WiseAccount::Transactions::Processor - No transactions for wise_account #{wise_account.id}"
    else
      Rails.logger.info "WiseAccount::Transactions::Processor - Processing #{total} transactions for wise_account #{wise_account.id}"
    end

    imported = 0
    failed = 0
    skipped = 0
    errors = []
    expected_ids = Set.new
    row_dates = []

    rows.each_with_index do |tx_data, index|
      processor = processor_for(tx_data)
      result = processor.process
      expected_ids.merge(processor.expected_external_ids)
      row_dates << processor.booking_date

      case result
      when :skipped
        skipped += 1
      when nil
        failed += 1
        errors << { index: index, error: "No transaction imported" }
      else
        imported += 1
      end
    rescue ArgumentError => e
      failed += 1
      Rails.logger.error "WiseAccount::Transactions::Processor - Validation error at index #{index}: #{e.message}"
      errors << { index: index, error: e.message }
    rescue => e
      failed += 1
      Rails.logger.error "WiseAccount::Transactions::Processor - Error at index #{index}: #{e.class} - #{e.message}"
      Rails.logger.error Array(e.backtrace).first(10).join("\n")
      errors << { index: index, error: "#{e.class}: #{e.message}" }
    end

    prune = prune?(payload, failed) ? prune_stale_entries(rows, expected_ids, row_dates) : { destroyed: 0, kept: 0 }
    Rails.logger.info "WiseAccount::Transactions::Processor - Done: #{imported} imported, #{skipped} skipped, #{failed} failed, #{prune[:destroyed]} stale deleted"

    { success: failed == 0, total: total, imported: imported, skipped: skipped, failed: failed, errors: errors,
      pruned: prune[:destroyed], prune_kept: prune[:kept] }
  end

  private

    # The row's kind, not its type, picks the processor: a statement row,
    # an activity row (any activity type the importer stored, see
    # WiseActivity::Processor.activity_row?), else a /v1/transfers row.
    def processor_for(tx_data)
      if tx_data["wise_statement"].present?
        WiseStatement::Processor.new(tx_data, wise_account: wise_account)
      elsif WiseActivity::Processor.activity_row?(tx_data)
        WiseActivity::Processor.new(tx_data, wise_account: wise_account)
      else
        WiseEntry::Processor.new(tx_data, wise_account: wise_account, own_recipient_ids: own_recipient_ids,
                                          recipient_owners: recipient_owners)
      end
    end

    # Looked up once per run rather than once per transfer.
    def own_recipient_ids
      @own_recipient_ids ||= wise_account.wise_item.own_recipient_ids
    end

    def recipient_owners
      @recipient_owners ||= wise_account.wise_item.balance_recipient_owners
    end

    def account
      @account ||= wise_account.current_account
    end

    # The payload speaks for the balance only after an import that fetched
    # everything (nil: nothing was ever stored for it), and only if every
    # row was processed. A closed balance's payload is frozen as it was, and
    # nothing is deleted once the balance's processing lock was lost
    # (WiseAccount#processing_lock_lost?).
    def prune?(payload, failed)
      import_complete && payload.is_a?(Array) && failed.zero? && !wise_account.closed? && account.present? &&
        !wise_account.processing_lock_lost?
    end

    # Deletes the Wise entries no stored row books any more: a leg routed to
    # this balance by an older rule, a payout Wise cancelled or the balance
    # replay found paid by card, a split part now 0. Entries a person acted
    # on stay (#protected_entry?), and nothing is deleted when there are too
    # many (#prune_cap) unless this sync re-fetched the whole history.
    # Logged with the external ids.
    def prune_stale_entries(rows, expected_ids, row_dates)
      stale = stale_entries(rows, expected_ids, row_dates)
      return { destroyed: 0, kept: 0 } if stale.empty?

      kept, doomed = stale.partition { |entry| protected_entry?(entry) }
      cap = prune_cap
      capped = doomed.size > cap && !coverage_upgraded
      destroyed = []
      unless capped
        doomed.each do |entry|
          destroy_stale_entry(entry) ? destroyed << entry : kept << entry
        end
      end

      log_prune(destroyed: destroyed, kept: kept, capped: capped ? doomed : [], cap: cap,
                cap_bypassed: doomed.size > cap && coverage_upgraded)
      { destroyed: destroyed.size, kept: kept.size }
    rescue StandardError => e
      # The rows are booked by now; a failed clean-up only waits for the next sync.
      Rails.logger.error "WiseAccount::Transactions::Processor - Stale entry clean-up failed for wise_account #{wise_account.id}: #{e.class} - #{e.message}"
      Sentry.capture_exception(e) { |scope| scope.set_tags(wise_account_id: wise_account.id) }
      { destroyed: destroyed&.size.to_i, kept: 0 }
    end

    # Wise transaction entries on this balance that no row of the payload
    # expects (each processor's #expected_external_ids, none for a row that
    # books nothing here), booked since the balance was linked to the account
    # (an older one is an earlier connection's history) and dated from the
    # payload's earliest row on: the payload may not reach further back (a
    # shorter history). An empty payload has no date to go by, so only the
    # entries of routed rows count there.
    def stale_entries(rows, expected_ids, row_dates)
      scope = account.entries.where(source: "wise", entryable_type: "Transaction")
                     .where("entries.external_id LIKE ?", "wise\\_%")
                     .where.not(external_id: expected_ids.to_a)
                     .where(created_at: wise_account.account_provider.created_at..)

      if rows.empty?
        prefixes = ROUTED_EXTERNAL_ID_PREFIXES.map { |prefix| "#{Entry.sanitize_sql_like(prefix)}%" }
        scope = scope.where("entries.external_id LIKE ANY (ARRAY[?])", prefixes)
      else
        earliest = row_dates.compact.min
        return [] unless earliest

        scope = scope.where(date: earliest..)
      end

      # A balance that gained statements drops its card payments' activity
      # rows, but their entries are for the statement rows to take over
      # (renamed, keeping what a person did to them), not to be deleted.
      if rows.any? { |row| row["wise_statement"].present? }
        scope = scope.where.not("entries.external_id LIKE ?", "wise\\_activity\\_%")
      end

      scope.includes(:entryable).order(:date, :external_id).to_a
    end

    # What a person decided about an entry, which a re-routed row must not
    # take away: an edit or lock, notes, tags, receipts, a reconciliation, a
    # split, or a transfer they confirmed. Exclusion alone does not count,
    # since an excluded entry still moves the balance. Wise's own transfer
    # links do not count either (a pending suggestion, or a confirmed link
    # between two Wise entries of this item): they go with the entry, and the
    # next link run restores what still applies.
    def protected_entry?(entry)
      transaction = entry.entryable
      entry.user_modified? || entry.import_locked? || entry.reconciled_at.present? ||
        entry.locked_attributes.present? || transaction.locked_attributes.present? ||
        entry.notes.present? || transaction.taggings.exists? || transaction.attachments.attached? ||
        entry.split_parent? || person_transfer?(transaction)
    end

    def person_transfer?(transaction)
      # A fee another transfer carries.
      return true if transaction.transfer_id.present?

      [ transaction.transfer_as_inflow, transaction.transfer_as_outflow ].compact.any? { |transfer| !wise_link?(transfer) }
    end

    def wise_link?(transfer)
      return true if transfer.pending?

      [ transfer.inflow_transaction, transfer.outflow_transaction ].all? do |leg|
        entry = leg&.entry
        entry.present? && entry.source == "wise" && item_account_ids.include?(entry.account_id)
      end
    end

    def item_account_ids
      @item_account_ids ||= wise_account.wise_item.accounts.pluck(:id).to_set
    end

    def prune_cap
      [ PRUNE_CAP_MINIMUM, account.entries.where(source: "wise").count * PRUNE_CAP_SHARE ].max
    end

    # One entry at a time, each in a savepoint, so a failed delete cannot
    # abort a transaction the caller holds. The row lock and a second look
    # keep an entry a person changed meanwhile.
    def destroy_stale_entry(entry)
      Entry.transaction(requires_new: true) do
        entry.lock!
        next false if protected_entry?(entry)

        entry.destroy!
        true
      end
    rescue ActiveRecord::RecordNotFound
      false
    rescue StandardError => e
      Rails.logger.error "WiseAccount::Transactions::Processor - Could not delete stale entry #{entry.id}: #{e.class} - #{e.message}"
      false
    end

    def log_prune(destroyed:, kept:, capped:, cap:, cap_bypassed:)
      message =
        if capped.any?
          "#{capped.size} Wise entries no stored row books are more than one sync may delete (#{cap.to_f.round(1)}); none was deleted"
        else
          "Deleted #{destroyed.size} Wise entries no stored row books any more; kept #{kept.size} a person acted on"
        end

      DebugLogEntry.capture(
        category: "provider_sync",
        level: capped.any? || cap_bypassed ? "warn" : "info",
        message: "WiseAccount::Transactions::Processor - #{message}",
        source: self.class.name,
        provider_key: "wise",
        family: account.family,
        account_provider: wise_account.account_provider,
        metadata: {
          wise_item_id: wise_account.wise_item_id,
          wise_account_id: wise_account.id,
          currency: wise_account.currency,
          operation: "prune",
          destroyed_count: destroyed.size,
          destroyed_external_ids: logged_ids(destroyed),
          kept_count: kept.size,
          kept_external_ids: logged_ids(kept),
          capped_count: capped.size.nonzero?,
          capped_external_ids: logged_ids(capped),
          cap_bypassed: (true if cap_bypassed)
        }.compact
      )
    rescue StandardError => e
      Rails.logger.warn "WiseAccount::Transactions::Processor - Failed to capture Wise debug log: #{e.message}"
    end

    def logged_ids(entries)
      entries.first(MAX_LOGGED_EXTERNAL_IDS).map(&:external_id).presence
    end
end
