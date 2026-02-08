module Family::AutoTransferMatchable
  def transfer_match_candidates(date_window: 4, exchange_rate_tolerance: 0.1)
    Entry.select([
      "inflow_candidates.entryable_id as inflow_transaction_id",
      "outflow_candidates.entryable_id as outflow_transaction_id",
      "ABS(inflow_candidates.date - outflow_candidates.date) as date_diff"
    ]).from("entries inflow_candidates")
      .joins("
        JOIN entries outflow_candidates ON (
          inflow_candidates.amount < 0 AND
          outflow_candidates.amount > 0 AND
          inflow_candidates.account_id <> outflow_candidates.account_id AND
          inflow_candidates.date BETWEEN outflow_candidates.date - #{date_window.to_i} AND outflow_candidates.date + #{date_window.to_i}
        )
      ").joins("
        LEFT JOIN transfers existing_transfers ON (
          existing_transfers.inflow_transaction_id = inflow_candidates.entryable_id OR
          existing_transfers.outflow_transaction_id = outflow_candidates.entryable_id
        )
      ")
      .joins("LEFT JOIN rejected_transfers ON (
        rejected_transfers.inflow_transaction_id = inflow_candidates.entryable_id AND
        rejected_transfers.outflow_transaction_id = outflow_candidates.entryable_id
      )")
      .joins("LEFT JOIN exchange_rates ON (
        exchange_rates.date = outflow_candidates.date AND
        exchange_rates.from_currency = outflow_candidates.currency AND
        exchange_rates.to_currency = inflow_candidates.currency
      )")
      .joins("JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id")
      .joins("JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id")
      .where("inflow_accounts.family_id = ? AND outflow_accounts.family_id = ?", self.id, self.id)
      .where("inflow_accounts.status IN ('draft', 'active')")
      .where("outflow_accounts.status IN ('draft', 'active')")
      .where("inflow_candidates.entryable_type = 'Transaction' AND outflow_candidates.entryable_type = 'Transaction'")
      .where("
        (
          inflow_candidates.currency = outflow_candidates.currency AND
          inflow_candidates.amount = -outflow_candidates.amount
        ) OR (
          inflow_candidates.currency <> outflow_candidates.currency AND
          ABS(inflow_candidates.amount / NULLIF(outflow_candidates.amount * exchange_rates.rate, 0)) BETWEEN #{1 - exchange_rate_tolerance} AND #{1 + exchange_rate_tolerance}
        )
      ")
      .where(existing_transfers: { id: nil })
      .order("date_diff ASC") # Closest matches first
  end

  def auto_match_transfers!
    # Exclude already matched transfers
    candidates_scope = transfer_match_candidates.where(rejected_transfers: { id: nil })

    # Track which transactions we've already matched to avoid duplicates
    used_transaction_ids = Set.new

    candidates = []

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
        destination_account = Transaction.find(match.inflow_transaction_id).entry.account
        if Transfer.kind_for_account(destination_account) == "investment_contribution"
          outflow_txn = Transaction.find(match.outflow_transaction_id)
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
end
