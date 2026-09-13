module Family::AutoTransferMatchable
  # A confirmed IBAN match (the destination account's own IBAN equals the
  # outflow's recorded counterparty IBAN) is the most precise signal
  # available -- more precise than amount+date alone, which can be ambiguous
  # with several similar transactions in flight. It therefore gets a wider
  # date-tolerance window to absorb bank clearing delays; transactions
  # without a confirmed IBAN keep the existing, narrower window unchanged.
  #
  # Matches Transfer#transfer_within_date_range's own 30-day cap for
  # status: "confirmed" (the status this match gets once it needs the wider
  # window at all) -- a narrower value here would make the SQL candidate
  # lookup itself exclude confirmed-eligible matches between that value and
  # 30 days, before the model validation ever got a chance to allow them.
  IBAN_CONFIRMED_DATE_WINDOW = 30
  DEFAULT_DATE_WINDOW = 4

  def transfer_match_candidates(
    date_window: 4,
    exchange_rate_tolerance: 0.1,
    inflow_transaction_id: nil,
    outflow_transaction_id: nil,
    account_id: nil,
    include_rejected: true
  )
    date_window = coerce_transfer_match_date_window!(date_window)
    exchange_rate_tolerance = coerce_transfer_match_exchange_rate_tolerance!(exchange_rate_tolerance)

    Entry.find_by_sql([
      transfer_match_candidates_sql,
      {
        date_window:,
        family_id: id,
        inflow_transaction_id:,
        outflow_transaction_id:,
        account_id:,
        include_rejected:,
        lower_exchange_rate_bound: 1 - exchange_rate_tolerance,
        upper_exchange_rate_bound: 1 + exchange_rate_tolerance
      }
    ])
  end

  def auto_match_transfers!(account: nil)
    # Exclude already matched transfers. Loads the wider IBAN-confirmed window
    # up front; candidates that turn out not to be IBAN-confirmed are pruned
    # back down to the normal window just below, so unconfirmed behavior is
    # unchanged.
    candidates_scope = transfer_match_candidates(
      account_id: account&.id, include_rejected: false, date_window: IBAN_CONFIRMED_DATE_WINDOW
    )
    transaction_ids = candidates_scope.flat_map do |match|
      [ match.inflow_transaction_id, match.outflow_transaction_id ]
    end.uniq
    transactions_by_id = Transaction.includes(entry: :account).where(id: transaction_ids).index_by(&:id)

    # IBAN-confirmed candidates may use the wider window and are tried first;
    # everything else is restricted back to the original narrow window so
    # transactions with no IBAN data see no behavior change. Confirmation is
    # computed once per match and carried alongside it -- Transfer's own
    # transfer_within_date_range validation caps unconfirmed transfers at 4
    # days, so an IBAN-confirmed match also needs status: "confirmed" (its
    # 30-day cap) to actually persist beyond that.
    candidates_with_confirmation = candidates_scope
      .map { |match| [ match, iban_confirmed?(match, transactions_by_id) ] }
      .select { |match, confirmed| confirmed || match.date_diff <= DEFAULT_DATE_WINDOW }
      .sort_by { |match, confirmed| [ confirmed ? 0 : 1, match.date_diff ] }

    # Track which transactions we've already matched to avoid duplicates
    used_transaction_ids = Set.new
    investment_category = nil
    investment_category_loaded = false

    Transfer.transaction do
      candidates_with_confirmation.each do |match, confirmed|
        next if used_transaction_ids.include?(match.inflow_transaction_id) ||
               used_transaction_ids.include?(match.outflow_transaction_id)

        # status: "confirmed" is only for the IBAN-confirmed candidates that
        # actually NEED it to persist -- those beyond the default window,
        # where transfer_within_date_range would otherwise reject an
        # unconfirmed transfer. An IBAN-confirmed match that also falls
        # inside the default window would have matched without the IBAN
        # signal at all, so it must stay pending like every other automatic
        # match, not skip user review just because it happens to be
        # IBAN-confirmed too.
        needs_confirmed_status = confirmed && match.date_diff > DEFAULT_DATE_WINDOW

        # Skip this candidate when the transfer for this exact pair was not created
        # (a concurrent sync claimed one of the transactions for a different pairing);
        # marking it matched here would leave a transaction matched with no Transfer.
        next unless find_or_create_transfer!(match, confirmed: needs_confirmed_status)

        inflow_transaction = transactions_by_id.fetch(match.inflow_transaction_id)
        outflow_transaction = transactions_by_id.fetch(match.outflow_transaction_id)
        destination_account = inflow_transaction.entry.account
        transfer_kind = Transfer.kind_for_account(destination_account)

        # The kind is determined by the DESTINATION account (inflow), matching Transfer::Creator logic
        inflow_transaction.update!(kind: "funds_movement")
        outflow_transaction.update!(kind: transfer_kind)

        # Assign Investment Contributions category for transfers to investment accounts
        if transfer_kind == "investment_contribution"
          outflow_txn = outflow_transaction
          if outflow_txn.category_id.blank?
            unless investment_category_loaded
              investment_category = investment_contributions_category
              investment_category_loaded = true
            end
            outflow_txn.update!(category: investment_category) if investment_category.present?
          end
        end

        used_transaction_ids << match.inflow_transaction_id
        used_transaction_ids << match.outflow_transaction_id
      end
    end
  end

  # An outflow entry whose counterparty IBAN matches another of this
  # family's accounts (synced or manual) is a transfer whose destination
  # account is known, even though the matching inflow transaction doesn't
  # exist yet -- e.g. the destination is a manually-tracked account the
  # user hasn't recorded this deposit on. Returns that account, or nil when
  # there's nothing to suggest (no counterparty IBAN, no matching account,
  # already a transfer, or the user already dismissed this suggestion).
  #
  # Deliberately entry-scoped rather than family-wide: this only needs to
  # answer "should the transfer-match dialog for THIS entry pre-fill a
  # target account", not enumerate every missing counterpart across the
  # family (no UI surfaces that broader list yet).
  # user: required so the suggested account is restricted to the same
  # writable+visible set TransferMatchesController#new offers in its
  # target_account_id dropdown. Without it, a match on a disabled account or
  # one the current user has no access to (family sharing permissions) would
  # get preselected in the UI despite never appearing among the selectable
  # options -- and would leak that account's name/existence to a user who
  # can't otherwise see it.
  def missing_transfer_suggestion_for(entry, user:)
    return nil unless entry.amount.positive?

    transaction = entry.entryable
    return nil unless transaction.is_a?(Transaction)
    return nil if transaction.transfer?
    return nil if transaction.extra&.dig("counterparty_transfer_suggestion_dismissed") == true

    counterparty_iban = transaction.extra&.dig("counterparty_iban")
    return nil if counterparty_iban.blank?

    accounts.writable_by(user).visible.where.not(id: entry.account_id).find_by(iban: normalize_iban(counterparty_iban))
  end

  private
    # True when the inflow's destination account has its own IBAN set and it
    # matches the outflow transaction's recorded counterparty IBAN. Blank on
    # either side (no accounts.iban set, or the provider never supplied a
    # counterparty IBAN for this transaction) always resolves to false --
    # this is an additive signal, never a requirement.
    def iban_confirmed?(match, transactions_by_id)
      inflow = transactions_by_id[match.inflow_transaction_id]
      outflow = transactions_by_id[match.outflow_transaction_id]
      return false unless inflow && outflow

      destination_iban = inflow.entry.account.iban
      counterparty_iban = outflow.extra&.dig("counterparty_iban")
      return false if destination_iban.blank? || counterparty_iban.blank?
      return false unless normalize_iban(destination_iban) == normalize_iban(counterparty_iban)

      # The inflow side's own recorded counterparty IBAN (who the destination
      # account's bank says paid it) is a second, independent signal from the
      # same provider sync. When it's present, it must agree with the source
      # account's IBAN too -- a contradiction here (matching amount/date, but
      # the destination account's bank recorded a DIFFERENT payer) means this
      # is very likely two distinct transactions that merely coincide, not a
      # confirmed transfer. Blank is not a contradiction: not every provider
      # supplies this on the inflow side, so its absence is uninformative.
      source_iban = outflow.entry.account.iban
      inflow_counterparty_iban = inflow.extra&.dig("counterparty_iban")
      return false if source_iban.present? && inflow_counterparty_iban.present? &&
        normalize_iban(source_iban) != normalize_iban(inflow_counterparty_iban)

      true
    end

    def normalize_iban(value)
      IbanNormalizable.normalize(value).to_s
    end

    # Create the transfer for a matched candidate, tolerating a concurrent sync
    # that already inserted the same pair.
    #
    # The insert runs in its own savepoint (requires_new: true). On PostgreSQL a
    # failed statement aborts the entire surrounding transaction, so rescuing a
    # RecordNotUnique raised by find_or_create_by! is not enough on its own: the
    # next write would fail with PG::InFailedSqlTransaction and the remaining
    # candidates would be silently dropped. Isolating the insert in a savepoint
    # rolls back only the failed statement, leaving the outer transaction healthy.
    def find_or_create_transfer!(match, confirmed: false)
      Transfer.transaction(requires_new: true) do
        Transfer.find_or_create_by!(
          inflow_transaction_id: match.inflow_transaction_id,
          outflow_transaction_id: match.outflow_transaction_id,
        ) do |transfer|
          # Only takes effect when a new record is being built -- an
          # already-existing transfer's status is left untouched. Needed so
          # an IBAN-confirmed match beyond the default 4-day window doesn't
          # immediately fail transfer_within_date_range, which only allows
          # up to 30 days for status: "confirmed".
          transfer.status = "confirmed" if confirmed
        end
      end
    rescue ActiveRecord::RecordNotUnique
      # The composite unique index rejected the insert because this exact
      # (inflow, outflow) pair was committed concurrently between our find and our
      # insert. Return that committed row; if it is somehow absent, return nil so the
      # caller skips rather than marking a transaction with no Transfer behind it.
      existing_transfer(match)
    rescue ActiveRecord::RecordInvalid => e
      # The same race surfaces through the per-column uniqueness validation. Re-raise
      # anything that is not a :taken on the transfer's transaction ids...
      raise unless %i[inflow_transaction_id outflow_transaction_id].any? { |attr| e.record.errors.of_kind?(attr, :taken) }
      # ...and even for :taken, only accept it once the exact (inflow, outflow) row is
      # confirmed present; otherwise the :taken came from a different pairing.
      existing_transfer(match)
    end

    # The committed transfer for this exact candidate pair, or nil if none exists.
    def existing_transfer(match)
      Transfer.find_by(
        inflow_transaction_id: match.inflow_transaction_id,
        outflow_transaction_id: match.outflow_transaction_id,
      )
    end

    def coerce_transfer_match_date_window!(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "date_window must be an integer"
    end

    def coerce_transfer_match_exchange_rate_tolerance!(value)
      tolerance = begin
        Float(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "exchange_rate_tolerance must be numeric"
      end

      raise ArgumentError, "exchange_rate_tolerance must be numeric" unless tolerance.finite?
      raise ArgumentError, "exchange_rate_tolerance must be non-negative" if tolerance.negative?

      tolerance
    end

    def transfer_match_candidates_sql
      <<~SQL.squish
        SELECT transfer_match_candidates.*
        FROM (
          SELECT
            inflow_candidates.entryable_id AS inflow_transaction_id,
            outflow_candidates.entryable_id AS outflow_transaction_id,
            ABS(inflow_candidates.date - outflow_candidates.date) AS date_diff,
            rejected_transfers.id AS rejected_transfer_id
          FROM entries inflow_candidates
          JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id
          JOIN entries outflow_candidates ON (
            outflow_candidates.entryable_type = 'Transaction' AND
            outflow_candidates.excluded = FALSE AND
            outflow_candidates.amount > 0 AND
            outflow_candidates.account_id <> inflow_candidates.account_id AND
            outflow_candidates.date BETWEEN inflow_candidates.date - :date_window AND inflow_candidates.date + :date_window AND
            outflow_candidates.currency = inflow_candidates.currency AND
            outflow_candidates.amount = -inflow_candidates.amount
          )
          JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id
          LEFT JOIN transfers existing_transfers ON (
            existing_transfers.inflow_transaction_id = inflow_candidates.entryable_id OR
            existing_transfers.outflow_transaction_id = outflow_candidates.entryable_id
          )
          LEFT JOIN rejected_transfers ON (
            rejected_transfers.inflow_transaction_id = inflow_candidates.entryable_id AND
            rejected_transfers.outflow_transaction_id = outflow_candidates.entryable_id
          )
          WHERE
            inflow_candidates.entryable_type = 'Transaction' AND
            inflow_candidates.excluded = FALSE AND
            inflow_candidates.amount < 0 AND
            inflow_accounts.family_id = :family_id AND
            outflow_accounts.family_id = :family_id AND
            inflow_accounts.status IN ('draft', 'active') AND
            outflow_accounts.status IN ('draft', 'active') AND
            existing_transfers.id IS NULL AND
            (:account_id IS NULL OR inflow_candidates.account_id = :account_id OR outflow_candidates.account_id = :account_id) AND
            (:inflow_transaction_id IS NULL OR inflow_candidates.entryable_id = :inflow_transaction_id) AND
            (:outflow_transaction_id IS NULL OR outflow_candidates.entryable_id = :outflow_transaction_id) AND
            (:include_rejected = TRUE OR rejected_transfers.id IS NULL)
          UNION ALL
          SELECT
            inflow_candidates.entryable_id AS inflow_transaction_id,
            outflow_candidates.entryable_id AS outflow_transaction_id,
            ABS(inflow_candidates.date - outflow_candidates.date) AS date_diff,
            rejected_transfers.id AS rejected_transfer_id
          FROM entries inflow_candidates
          JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id
          JOIN entries outflow_candidates ON (
            outflow_candidates.entryable_type = 'Transaction' AND
            outflow_candidates.excluded = FALSE AND
            outflow_candidates.amount > 0 AND
            outflow_candidates.account_id <> inflow_candidates.account_id AND
            outflow_candidates.date BETWEEN inflow_candidates.date - :date_window AND inflow_candidates.date + :date_window AND
            outflow_candidates.currency <> inflow_candidates.currency
          )
          JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id
          JOIN exchange_rates ON (
            exchange_rates.date = outflow_candidates.date AND
            exchange_rates.from_currency = outflow_candidates.currency AND
            exchange_rates.to_currency = inflow_candidates.currency
          )
          LEFT JOIN transfers existing_transfers ON (
            existing_transfers.inflow_transaction_id = inflow_candidates.entryable_id OR
            existing_transfers.outflow_transaction_id = outflow_candidates.entryable_id
          )
          LEFT JOIN rejected_transfers ON (
            rejected_transfers.inflow_transaction_id = inflow_candidates.entryable_id AND
            rejected_transfers.outflow_transaction_id = outflow_candidates.entryable_id
          )
          WHERE
            inflow_candidates.entryable_type = 'Transaction' AND
            inflow_candidates.excluded = FALSE AND
            inflow_candidates.amount < 0 AND
            inflow_accounts.family_id = :family_id AND
            outflow_accounts.family_id = :family_id AND
            inflow_accounts.status IN ('draft', 'active') AND
            outflow_accounts.status IN ('draft', 'active') AND
            existing_transfers.id IS NULL AND
            (:account_id IS NULL OR inflow_candidates.account_id = :account_id OR outflow_candidates.account_id = :account_id) AND
            ABS(inflow_candidates.amount / NULLIF(outflow_candidates.amount * exchange_rates.rate, 0))
              BETWEEN :lower_exchange_rate_bound AND :upper_exchange_rate_bound AND
            (:inflow_transaction_id IS NULL OR inflow_candidates.entryable_id = :inflow_transaction_id) AND
            (:outflow_transaction_id IS NULL OR outflow_candidates.entryable_id = :outflow_transaction_id) AND
            (:include_rejected = TRUE OR rejected_transfers.id IS NULL)
        ) transfer_match_candidates
        ORDER BY transfer_match_candidates.date_diff ASC
      SQL
    end
end
