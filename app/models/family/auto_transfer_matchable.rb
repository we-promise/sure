module Family::AutoTransferMatchable
  def transfer_match_candidates(
    date_window: 4,
    exchange_rate_tolerance: 0.1,
    inflow_transaction_id: nil,
    outflow_transaction_id: nil,
    account_id: nil,
    include_rejected: true,
    since_date: nil
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
        since_date: since_date&.to_date,
        lower_exchange_rate_bound: 1 - exchange_rate_tolerance,
        upper_exchange_rate_bound: 1 + exchange_rate_tolerance
      }
    ])
  end

  # since_date bounds the scan to recently-dated entries; nil matches across
  # full history. Family-level syncs pass a bound (matching runs after every
  # sync, so older pairs were already considered by previous runs), while
  # account-level syncs keep full history for the single account.
  def auto_match_transfers!(account: nil, since_date: nil)
    # Exclude already matched transfers
    candidates_scope = transfer_match_candidates(account_id: account&.id, include_rejected: false, since_date: since_date)
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

        begin
          Transfer.find_or_create_by!(
            inflow_transaction_id: match.inflow_transaction_id,
            outflow_transaction_id: match.outflow_transaction_id,
          )
        rescue ActiveRecord::RecordNotUnique
          # Another concurrent job created the transfer; safe to ignore
        end

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
            (:since_date IS NULL OR inflow_candidates.date >= :since_date) AND
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
            (:since_date IS NULL OR inflow_candidates.date >= :since_date) AND
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
