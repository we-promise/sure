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
  # The fetches each kind of entry's rows come from: a transfer's entries
  # from the transfer list and its activities (its fee and refund), an
  # activity's (conversion legs included) from the activities, a statement
  # row's from the balance's statements.
  COVERAGE_SOURCES = {
    "wise_transfer_" => %i[transfers activities], "wise_fee_" => %i[transfers activities],
    "wise_refund_" => %i[transfers activities], "wise_interbalance_" => %i[activities],
    "wise_activity_" => %i[activities], "wise_statement_" => %i[statements]
  }.freeze
  MAX_LOGGED_EXTERNAL_IDS = 20

  attr_reader :wise_account, :import_complete

  # import_complete: see WiseItem#process_accounts.
  def initialize(wise_account, import_complete: false)
    @wise_account = wise_account
    @import_complete = import_complete
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
    # { kind of rename => { outcome => external ids } } (#take_over_entries).
    @rekeys = Hash.new { |kinds, kind| kinds[kind] = Hash.new { |outcomes, outcome| outcomes[outcome] = [] } }

    rows.each_with_index do |tx_data, index|
      processor = processor_for(tx_data)
      take_over_entries(processor)
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

    log_rekeys
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

    # A statement row that carries the movement of a row the balance booked
    # before it had statements (WiseItem::StatementMigration) first takes
    # that row's entries over, main entry and fee together, so they keep
    # what a person did to them: renamed to the statement row's ids when
    # those are free. When both exist (an older migration booked both), the
    # one a person acted on or linked stays under the statement id and the
    # other is deleted; if a person acted on both, both stay (logged).
    # Deleting waits for a complete import. A jar move's leg takes over its
    # entry booked on the other side the same way (WiseActivity::Processor
    # #superseded_external_ids).
    def take_over_entries(processor)
      return unless account.present? && processor.respond_to?(:superseded_external_ids)

      mapping = processor.superseded_external_ids
      # Every jar move names its other side, and most have no entry under it,
      # so the account's ids are read once per run (#entry_external_ids).
      return if mapping.empty? || mapping.keys.none? { |external_id| entry_external_ids.include?(external_id) }

      rekeys = @rekeys[processor.is_a?(WiseStatement::Processor) ? :statement : :leg_side]
      outcomes = Entry.transaction(requires_new: true) { mapping.map { |from, to| rekey_entry(from, to) } }
      outcomes.each { |outcome, external_id| rekeys[outcome] << external_id unless outcome == :none }
      mapping.each_key.zip(outcomes) do |from, (outcome, _external_id)|
        entry_external_ids.delete(from) if %i[renamed replaced dropped].include?(outcome)
      end
    rescue StandardError
      # The row fails rather than book a second entry next to the old one;
      # the next sync tries again.
      rekeys[:failed].concat(Array(mapping&.keys)) if rekeys
      raise
    end

    # [outcome, the external id it concerns]; destroyed entries are named by
    # the id they had.
    def rekey_entry(from, to)
      scope = account.entries.where(source: "wise", entryable_type: "Transaction")
      old = scope.lock.find_by(external_id: from)
      return [ :none, from ] unless old

      current = scope.lock.find_by(external_id: to)
      if current.nil?
        old.update!(external_id: to)
        [ :renamed, to ]
      elsif !import_complete || wise_account.processing_lock_lost?
        [ :deferred, from ]
      elsif keep_rank(old) > keep_rank(current) && !protected_entry?(current)
        current.destroy!
        old.update!(external_id: to)
        [ :replaced, to ]
      elsif !protected_entry?(old)
        old.destroy!
        [ :dropped, from ]
      else
        [ :kept_both, from ]
      end
    end

    # Which of two entries for one movement to keep: one a person acted on
    # (#protected_entry?), then one in a transfer (a suggestion included),
    # then one not excluded (a person may have hidden the other copy).
    def keep_rank(entry)
      return 3 if protected_entry?(entry)

      transaction = entry.entryable
      return 2 if transaction.transfer_as_inflow.present? || transaction.transfer_as_outflow.present?

      entry.excluded? ? 0 : 1
    end

    # One DebugLogEntry per kind of rename that did anything this run.
    def log_rekeys
      @rekeys.each do |kind, rekeys|
        next if rekeys.values.all?(&:empty?)

        taken = rekeys[:renamed].size + rekeys[:replaced].size
        if kind == :statement
          log_rekey(rekeys, operation: "statement_rekey",
                            message: "Statement rows took over #{taken} Wise entries booked before the balance had statements")
        else
          log_rekey(rekeys, operation: "leg_side_rekey",
                            message: "Renamed #{taken} Wise jar move entries to the side of the move they are booked on")
        end
      end
    end

    def log_rekey(rekeys, operation:, message:)
      warn = rekeys[:kept_both].any? || rekeys[:failed].any?
      DebugLogEntry.capture(
        category: "provider_sync",
        level: warn ? "warn" : "info",
        message: "WiseAccount::Transactions::Processor - #{message}",
        source: self.class.name,
        provider_key: "wise",
        family: account.family,
        account_provider: wise_account.account_provider,
        metadata: {
          wise_item_id: wise_account.wise_item_id,
          wise_account_id: wise_account.id,
          currency: wise_account.currency,
          operation: operation,
          renamed_count: rekeys[:renamed].size,
          replaced_count: rekeys[:replaced].size.nonzero?,
          replaced_external_ids: rekeys[:replaced].first(MAX_LOGGED_EXTERNAL_IDS).presence,
          dropped_count: rekeys[:dropped].size.nonzero?,
          dropped_external_ids: rekeys[:dropped].first(MAX_LOGGED_EXTERNAL_IDS).presence,
          deferred_count: rekeys[:deferred].size.nonzero?,
          kept_both_count: rekeys[:kept_both].size.nonzero?,
          kept_both_external_ids: rekeys[:kept_both].first(MAX_LOGGED_EXTERNAL_IDS).presence,
          failed_count: rekeys[:failed].size.nonzero?
        }.compact
      )
    rescue StandardError => e
      Rails.logger.warn "WiseAccount::Transactions::Processor - Failed to capture Wise debug log: #{e.message}"
    end

    # The external ids of the account's Wise entries, as renames leave them.
    def entry_external_ids
      @entry_external_ids ||= account.entries.where(source: "wise").pluck(:external_id).to_set
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
    # everything (nil: nothing was ever stored for it), only if every row was
    # processed, and only where Sure knows what it fetched (#first_covered_days).
    # A closed balance's payload is frozen as it was, and nothing is deleted
    # once the balance's processing lock was lost (WiseAccount#processing_lock_lost?).
    def prune?(payload, failed)
      import_complete && payload.is_a?(Array) && failed.zero? && !wise_account.closed? && account.present? &&
        first_covered_days.any? && !wise_account.processing_lock_lost?
    end

    # Deletes the Wise entries no stored row books any more: a leg routed to
    # this balance by an older rule, a payout Wise cancelled or the balance
    # replay found paid by card, a split part now 0, a statement row of a
    # conversion whose own row books it, an activity a statement row books
    # under a reference Sure could not match. Entries a person acted
    # on stay (#protected_entry?). When there are too many (#prune_cap),
    # only those whose rows a sync that re-fetched the whole history moved
    # out of the payload go (WiseAccount#prune_cap_bypass_ids, spent once
    # this has run); the rest wait. Logged with the external ids.
    def prune_stale_entries(rows, expected_ids, row_dates)
      destroyed = []
      stale = stale_entries(rows, expected_ids, row_dates)
      kept, doomed = stale.partition { |entry| protected_entry?(entry) }
      cap = doomed.empty? ? 0 : prune_cap
      capped = []
      bypassed = false
      if doomed.size > cap
        moved = wise_account.prune_cap_bypass_ids.to_set
        capped = doomed.reject { |entry| moved.include?(entry.external_id) }
        doomed -= capped
        bypassed = doomed.any?
      end
      doomed.each do |entry|
        destroy_stale_entry(entry) ? destroyed << entry : kept << entry
      end

      log_prune(destroyed: destroyed, kept: kept, capped: capped, cap: cap, cap_bypassed: bypassed) if stale.any?
      wise_account.spend_prune_cap_bypass!
      { destroyed: destroyed.size, kept: kept.size }
    rescue StandardError => e
      # The rows are booked by now; a failed clean-up only waits for the next sync.
      Rails.logger.error "WiseAccount::Transactions::Processor - Stale entry clean-up failed for wise_account #{wise_account.id}: #{e.class} - #{e.message}"
      Sentry.capture_exception(e) { |scope| scope.set_tags(wise_account_id: wise_account.id) }
      { destroyed: destroyed.size, kept: 0 }
    end

    # Wise transaction entries on this balance that no row of the payload
    # expects (each processor's #expected_external_ids, none for a row that
    # books nothing here), booked since the balance was linked to the account
    # (an older one is an earlier connection's history), dated where Sure
    # fetched every row of their kind (#first_covered_days) and from the
    # payload's earliest row on: before that an entry can stand for a movement
    # Sure never fetched (a shorter history), unless a row the item holds
    # booked it (WiseAccount#prune_cap_bypass_ids). An empty payload has no
    # row to date by, and only the entries of routed rows count there.
    def stale_entries(rows, expected_ids, row_dates)
      first_days = first_covered_days
      first_days = first_days.slice(*ROUTED_EXTERNAL_ID_PREFIXES) if rows.empty?
      return [] if first_days.empty?

      scope = account.entries.where(source: "wise", entryable_type: "Transaction")
                     .where.not(external_id: expected_ids.to_a)
                     .where(created_at: wise_account.account_provider.created_at..)
      unless rows.empty?
        earliest = row_dates.compact.min
        dated = earliest ? scope.where(date: earliest..) : scope.none
        explained = wise_account.prune_cap_bypass_ids
        scope = explained.any? ? dated.or(scope.where(external_id: explained)) : dated
      end

      covered = first_days.map do |prefix, day|
        Entry.sanitize_sql_array([ "(entries.external_id LIKE ? AND entries.date >= ?)", "#{Entry.sanitize_sql_like(prefix)}%", day ])
      end
      scope.where(covered.join(" OR ")).includes(:entryable).order(:date, :external_id).to_a
    end

    # { external id prefix => the first day, in the family's zone, from which
    # every fetch its rows come from (COVERAGE_SOURCES) covered the whole
    # day }, for the kinds of entries all of whose fetches have coverage.
    def first_covered_days
      return @first_covered_days if defined?(@first_covered_days)

      wise_item = wise_account.wise_item
      starts = { transfers: wise_item.fetch_coverage(:transfers)&.dig(:from),
                 activities: wise_item.fetch_coverage(:activities)&.dig(:from),
                 statements: wise_account.statements_coverage&.dig(:from) }

      @first_covered_days = COVERAGE_SOURCES.each_with_object({}) do |(prefix, sources), days|
        froms = starts.values_at(*sources)
        next unless froms.all?

        start = froms.max.in_time_zone(wise_item.time_zone)
        days[prefix] = start == start.beginning_of_day ? start.to_date : start.to_date.next_day
      end
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
        if capped.any? && destroyed.any?
          "Deleted #{destroyed.size} Wise entries whose rows a full re-fetch moved out of the payload; #{capped.size} more " \
          "no stored row books are more than one sync may delete (#{cap.to_f.round(1)}) and stay"
        elsif capped.any?
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
