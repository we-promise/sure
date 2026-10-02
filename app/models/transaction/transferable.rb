module Transaction::Transferable
  extend ActiveSupport::Concern

  included do
    has_one :transfer_as_inflow, class_name: "Transfer", foreign_key: "inflow_transaction_id", dependent: :destroy
    has_one :transfer_as_outflow, class_name: "Transfer", foreign_key: "outflow_transaction_id", dependent: :destroy

    # We keep track of rejected transfers to avoid auto-matching them again
    has_one :rejected_transfer_as_inflow, class_name: "RejectedTransfer", foreign_key: "inflow_transaction_id", dependent: :destroy
    has_one :rejected_transfer_as_outflow, class_name: "RejectedTransfer", foreign_key: "outflow_transaction_id", dependent: :destroy
  end

  def transfer
    transfer_as_inflow || transfer_as_outflow
  end

  # Whether the UI shows the Transfer/Payment badge in place of the
  # transaction's own category. An unconfirmed auto-match keeps its standard
  # kind (see Transfer#confirm!) and still counts under its own category, so
  # it keeps showing that category until the user confirms the match.
  # Confirmed transfers linked without a transfer kind (e.g. Wise interbalance
  # moves) keep showing the badge.
  def shows_transfer_category?
    return false if transfer.nil? || transfer.categorizable?

    transfer? || transfer.confirmed?
  end

  def transfer_match_candidates(
    date_window: 30,
    exchange_rate_tolerance: Family::AutoTransferMatchable.manual_match_exchange_rate_tolerance
  )
    candidates_scope = if self.entry.amount.negative?
      family_matches_scope(date_window: date_window, exchange_rate_tolerance: exchange_rate_tolerance, inflow_transaction_id: self.id)
    else
      family_matches_scope(date_window: date_window, exchange_rate_tolerance: exchange_rate_tolerance, outflow_transaction_id: self.id)
    end

    candidates_scope.map do |match|
      Transfer.new(
        inflow_transaction_id: match.inflow_transaction_id,
        outflow_transaction_id: match.outflow_transaction_id,
      )
    end
  end

  private
    def family_matches_scope(date_window:, **filters)
      self.entry.account.family.transfer_match_candidates(date_window: date_window, **filters)
    end
end
