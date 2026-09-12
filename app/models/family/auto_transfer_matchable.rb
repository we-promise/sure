module Family::AutoTransferMatchable
  # Real-world FX slippage between a transaction's timestamp and the cached daily
  # rate is typically 1-3%. A wider band (the previous default was 10%) turns the
  # cross-currency branch into a coincidence match on round-number amounts. This
  # tight default is for the automatic path, where no human reviews the match.
  DEFAULT_EXCHANGE_RATE_TOLERANCE = 0.03

  # The manual "match as transfer" dialog (Transaction#transfer_match_candidates)
  # needs a wider band: a user is confirming the match themselves, and real-world
  # FX slippage/card-network markup on a manual-account leg can exceed 3%. Mirrors
  # the same date_window: 30 vs. 4 widening that dialog already applies.
  MANUAL_MATCH_EXCHANGE_RATE_TOLERANCE = 0.1

  def transfer_match_candidates(
    date_window: 4,
    exchange_rate_tolerance: DEFAULT_EXCHANGE_RATE_TOLERANCE,
    inflow_transaction_id: nil,
    outflow_transaction_id: nil,
    account_id: nil,
    include_rejected: true,
    restrict_cross_currency_to_linked_accounts: false
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
        restrict_cross_currency_to_linked_accounts:,
        lower_exchange_rate_bound: 1 - exchange_rate_tolerance,
        upper_exchange_rate_bound: 1 + exchange_rate_tolerance
      }
    ])
  end

  def auto_match_transfers!(account: nil, exchange_rate_tolerance: DEFAULT_EXCHANGE_RATE_TOLERANCE)
    # Exclude already matched transfers. Cross-currency FX-tolerance matching is
    # restricted to provider-linked accounts ONLY on this automatic path -- a
    # coincidental amount/FX-rate match applied here has no human reviewing it
    # first. The manual "match as transfer" dialog goes through
    # Transaction#transfer_match_candidates, which calls transfer_match_candidates
    # directly without this restriction, so a user can still find and confirm a
    # real cross-currency transfer that happens to involve a manual account.
    candidates_scope = transfer_match_candidates(
      account_id: account&.id,
      include_rejected: false,
      exchange_rate_tolerance:,
      restrict_cross_currency_to_linked_accounts: true
    )
    transaction_ids = candidates_scope.flat_map do |match|
      [ match.inflow_transaction_id, match.outflow_transaction_id ]
    end.uniq
    transactions_by_id = Transaction.includes(entry: :account).where(id: transaction_ids).index_by(&:id)

    # Track which transactions we've already matched to avoid duplicates
    used_transaction_ids = Set.new
    investment_category = nil
    investment_category_loaded = false

    Transfer.transaction do
      candidates_scope.each do |match|
        next if used_transaction_ids.include?(match.inflow_transaction_id) ||
               used_transaction_ids.include?(match.outflow_transaction_id)

        # Skip this candidate when the transfer for this exact pair was not created
        # (a concurrent sync claimed one of the transactions for a different pairing);
        # marking it matched here would leave a transaction matched with no Transfer.
        next unless find_or_create_transfer!(match)

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

  private
    # Create the transfer for a matched candidate, tolerating a concurrent sync
    # that already inserted the same pair.
    #
    # The insert runs in its own savepoint (requires_new: true). On PostgreSQL a
    # failed statement aborts the entire surrounding transaction, so rescuing a
    # RecordNotUnique raised by find_or_create_by! is not enough on its own: the
    # next write would fail with PG::InFailedSqlTransaction and the remaining
    # candidates would be silently dropped. Isolating the insert in a savepoint
    # rolls back only the failed statement, leaving the outer transaction healthy.
    def find_or_create_transfer!(match)
      Transfer.transaction(requires_new: true) do
        Transfer.find_or_create_by!(
          inflow_transaction_id: match.inflow_transaction_id,
          outflow_transaction_id: match.outflow_transaction_id,
        )
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

    # The second UNION branch below (cross-currency, FX-rate-tolerance matching) is a
    # coincidence guess -- amount x FX-rate within a tolerance band, not an exact amount
    # match -- and a manual account has no institution behind it confirming money actually
    # moved, so an unrelated pair of round-number transactions can land inside the tolerance
    # band purely by chance. When :restrict_cross_currency_to_linked_accounts is true, that
    # branch additionally requires both accounts to have a live provider connection
    # (Plaid/SimpleFIN/account_providers). Manual accounts always participate in the first
    # branch's exact-amount, same-currency matching, which carries no such ambiguity.
    #
    # The restriction is opt-in (default false) rather than baked into the branch
    # unconditionally: Family#auto_match_transfers! passes true because a coincidental match
    # there is applied automatically with no human reviewing it first, but
    # Transaction#transfer_match_candidates (the manual "match as transfer" dialog) leaves it
    # off so a user can still find and confirm a real cross-currency transfer that happens to
    # involve a manual account, rather than being forced into creating a duplicate.
    #
    # NOTE: this is passed through `.squish`, which collapses all whitespace (including
    # newlines) into single spaces -- a `--` SQL line comment anywhere in this heredoc would
    # swallow the remainder of the query. Put explanatory comments here in Ruby instead.
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
            (:include_rejected = TRUE OR rejected_transfers.id IS NULL) AND
            (
              :restrict_cross_currency_to_linked_accounts = FALSE OR
              (#{linked_account_sql("inflow_accounts")} AND #{linked_account_sql("outflow_accounts")})
            )
        ) transfer_match_candidates
        ORDER BY transfer_match_candidates.date_diff ASC
      SQL
    end

    # The inverse of Account#manual? / the Account.manual scope, inlined as SQL so
    # it can run against the inflow/outflow account aliases in the same query
    # rather than round-tripping through AR. Keep in sync with Account#manual? if
    # what counts as "linked" ever changes (e.g. a new provider type).
    def linked_account_sql(accounts_alias)
      <<~SQL.squish
        (
          #{accounts_alias}.plaid_account_id IS NOT NULL OR
          #{accounts_alias}.simplefin_account_id IS NOT NULL OR
          EXISTS (SELECT 1 FROM account_providers WHERE account_providers.account_id = #{accounts_alias}.id)
        )
      SQL
    end
end
