module Family::CardChangeMatchable
  # A detected "card-change reimbursement" trio:
  #   original  (T1) - the real purchase on account A (kept as the expense)
  #   outflow   (T2) - the new card actually charged on account B
  #   inflow    (T3) - the reimbursement back to account A
  # Linking T2 <-> T3 as a transfer nets them to zero, leaving T1 as the single expense.
  CardChangeCandidate = Data.define(
    :original_transaction_id,
    :outflow_transaction_id,
    :inflow_transaction_id
  )

  # Detects card-change reimbursement trios across the provider's retroactive
  # card-switch window. Same-currency, exact-amount matches only (v1).
  #
  #   purchase_window      - max days between the original purchase (T1) and the reimbursement (T3)
  #   reimbursement_window - max days between the new-card charge (T2) and the reimbursement (T3)
  #   reimbursement_slack  - days the reimbursement may post before the charge
  def card_change_reimbursement_candidates(
    purchase_window: 180,
    reimbursement_window: 45,
    reimbursement_slack: 3
  )
    purchase_window = Integer(purchase_window)
    reimbursement_window = Integer(reimbursement_window)
    reimbursement_slack = Integer(reimbursement_slack)

    rows = ActiveRecord::Base.connection.select_all(
      ActiveRecord::Base.sanitize_sql_array([
        card_change_candidates_sql,
        {
          family_id: id,
          purchase_window: purchase_window,
          reimbursement_window: reimbursement_window,
          reimbursement_slack: reimbursement_slack
        }
      ])
    )

    rows.map do |row|
      CardChangeCandidate.new(
        original_transaction_id: row["original_transaction_id"],
        outflow_transaction_id: row["outflow_transaction_id"],
        inflow_transaction_id: row["inflow_transaction_id"]
      )
    end
  end

  private
    def card_change_candidates_sql
      <<~SQL.squish
        SELECT DISTINCT ON (inflow_candidates.entryable_id, outflow_candidates.entryable_id)
          original_candidates.entryable_id AS original_transaction_id,
          outflow_candidates.entryable_id AS outflow_transaction_id,
          inflow_candidates.entryable_id AS inflow_transaction_id
        FROM entries inflow_candidates
        JOIN accounts inflow_accounts ON inflow_accounts.id = inflow_candidates.account_id
        /* T2: the new card charge on a different account */
        JOIN entries outflow_candidates ON (
          outflow_candidates.entryable_type = 'Transaction' AND
          outflow_candidates.excluded = FALSE AND
          outflow_candidates.amount > 0 AND
          outflow_candidates.account_id <> inflow_candidates.account_id AND
          outflow_candidates.currency = inflow_candidates.currency AND
          outflow_candidates.amount = -inflow_candidates.amount AND
          outflow_candidates.date <= inflow_candidates.date + :reimbursement_slack AND
          inflow_candidates.date - outflow_candidates.date <= :reimbursement_window
        )
        JOIN accounts outflow_accounts ON outflow_accounts.id = outflow_candidates.account_id
        /* T1: the original purchase on the reimbursed account (kept as the real expense) */
        JOIN entries original_candidates ON (
          original_candidates.entryable_type = 'Transaction' AND
          original_candidates.excluded = FALSE AND
          original_candidates.amount > 0 AND
          original_candidates.account_id = inflow_candidates.account_id AND
          original_candidates.currency = inflow_candidates.currency AND
          original_candidates.amount = outflow_candidates.amount AND
          original_candidates.entryable_id <> outflow_candidates.entryable_id AND
          original_candidates.date <= outflow_candidates.date AND
          inflow_candidates.date - original_candidates.date <= :purchase_window
        )
        JOIN transactions original_txns ON (
          original_txns.id = original_candidates.entryable_id AND
          original_txns.kind = 'standard'
        )
        /* Skip if any leg is already part of a transfer */
        LEFT JOIN transfers existing_transfers ON (
          existing_transfers.inflow_transaction_id IN (
            inflow_candidates.entryable_id, outflow_candidates.entryable_id, original_candidates.entryable_id
          ) OR
          existing_transfers.outflow_transaction_id IN (
            inflow_candidates.entryable_id, outflow_candidates.entryable_id, original_candidates.entryable_id
          )
        )
        /* Skip pairs the user already dismissed */
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
          rejected_transfers.id IS NULL
        ORDER BY
          inflow_candidates.entryable_id,
          outflow_candidates.entryable_id,
          original_candidates.date DESC
      SQL
    end
end
