module Transaction::Transferable
  extend ActiveSupport::Concern

  included do
    # inverse_of is load-bearing, not cosmetic: Transfer#categorizable? calls
    # from_account on every transfer row of the transactions index, which walks
    # transfer.outflow_transaction.entry.account. The index only preloads the
    # counterparty (inflow) leg, so without the inverse each outflow row
    # re-queries its own transaction, entry and account (an N+1 that
    # TransactionsControllerTest "index preloads transfer counterparty entry
    # and account to avoid N+1" catches).
    has_one :transfer_as_inflow, class_name: "Transfer", foreign_key: "inflow_transaction_id", inverse_of: :inflow_transaction, dependent: :destroy
    has_one :transfer_as_outflow, class_name: "Transfer", foreign_key: "outflow_transaction_id", inverse_of: :outflow_transaction, dependent: :destroy

    # We keep track of rejected transfers to avoid auto-matching them again
    has_one :rejected_transfer_as_inflow, class_name: "RejectedTransfer", foreign_key: "inflow_transaction_id", dependent: :destroy
    has_one :rejected_transfer_as_outflow, class_name: "RejectedTransfer", foreign_key: "outflow_transaction_id", dependent: :destroy
  end

  def transfer
    transfer_as_inflow || transfer_as_outflow
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

    candidates = candidates_scope.map do |match|
      Transfer.new(
        inflow_transaction_id: match.inflow_transaction_id,
        outflow_transaction_id: match.outflow_transaction_id,
      )
    end

    likeliest_first(candidates)
  end

  private
    # A pair the user already rejected goes last, and a counterpart in this
    # transaction's category goes first (and is preselected in the dialog), so
    # the dialog a list hint opens defaults to the kind of pair the hint found;
    # otherwise the query's order (exact amounts, then nearest date) stays.
    def likeliest_first(candidates)
      counterpart_id = ->(candidate) { candidate.inflow_transaction_id == id ? candidate.outflow_transaction_id : candidate.inflow_transaction_id }
      category_ids = Transaction.where(id: candidates.map(&counterpart_id)).pluck(:id, :category_id).to_h
      rejected_counterpart_ids = RejectedTransfer.where(inflow_transaction_id: id).pluck(:outflow_transaction_id) +
        RejectedTransfer.where(outflow_transaction_id: id).pluck(:inflow_transaction_id)

      candidates.each_with_index
                .sort_by do |candidate, index|
                  counterpart = counterpart_id.call(candidate)
                  [
                    rejected_counterpart_ids.include?(counterpart) ? 1 : 0,
                    category_ids[counterpart] == category_id ? 0 : 1,
                    index
                  ]
                end
                .map(&:first)
    end

    def family_matches_scope(date_window:, **filters)
      self.entry.account.family.transfer_match_candidates(date_window: date_window, **filters)
    end
end
