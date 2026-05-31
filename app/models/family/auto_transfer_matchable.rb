module Family::AutoTransferMatchable
  def transfer_match_candidates(
    date_window: 4,
    exchange_rate_tolerance: 0.1,
    inflow_transaction_id: nil,
    outflow_transaction_id: nil,
    include_rejected: true
  )
    date_window = date_window.to_i
    exchange_rate_tolerance = exchange_rate_tolerance.to_f

    Entry.find_by_sql([
      transfer_match_candidates_sql,
      {
        date_window:,
        family_id: id,
        inflow_transaction_id:,
        outflow_transaction_id:,
        include_rejected:,
        lower_exchange_rate_bound: 1 - exchange_rate_tolerance,
        upper_exchange_rate_bound: 1 + exchange_rate_tolerance
      }
    ])
  end

  def auto_match_transfers!
    # Exclude already matched transfers
    candidates_scope = transfer_match_candidates(include_rejected: false)

    # Track which transactions we've already matched to avoid duplicates
    used_transaction_ids = Set.new

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

        inflow_transaction = Transaction.find(match.inflow_transaction_id)
        outflow_transaction = Transaction.find(match.outflow_transaction_id)

        # The kind is determined by the DESTINATION account (inflow), matching Transfer::Creator logic
        inflow_transaction.update!(kind: "funds_movement")
        outflow_transaction.update!(kind: Transfer.kind_for_account(inflow_transaction.entry.account))

        # Assign Investment Contributions category for transfers to investment accounts
        destination_account = inflow_transaction.entry.account
        if Transfer.kind_for_account(destination_account) == "investment_contribution"
          outflow_txn = outflow_transaction
          if outflow_txn.category_id.blank?
            category = destination_account.family.investment_contributions_category
            outflow_txn.update!(category: category) if category.present?
          end
        end

        used_transaction_ids << match.inflow_transaction_id
        used_transaction_ids << match.outflow_transaction_id
      end
    end
  end

  private
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
            inflow_candidates.amount < 0 AND
            inflow_accounts.family_id = :family_id AND
            outflow_accounts.family_id = :family_id AND
            inflow_accounts.status IN ('draft', 'active') AND
            outflow_accounts.status IN ('draft', 'active') AND
            existing_transfers.id IS NULL AND
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
            inflow_candidates.amount < 0 AND
            inflow_accounts.family_id = :family_id AND
            outflow_accounts.family_id = :family_id AND
            inflow_accounts.status IN ('draft', 'active') AND
            outflow_accounts.status IN ('draft', 'active') AND
            existing_transfers.id IS NULL AND
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
