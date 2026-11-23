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

    # Legs and fees of the transfers that touch an account +user+ cannot open,
    # whose names may name that account (see #name_for).
    scope :with_counterpart_hidden_from, ->(user) {
      hidden_accounts = user.family.accounts.where.not(id: Account.accessible_by(user).select(:id))
      hidden_legs = Entry.where(account_id: hidden_accounts.select(:id), entryable_type: "Transaction").select(:entryable_id)
      transfers = Transfer.where(inflow_transaction_id: hidden_legs).or(Transfer.where(outflow_transaction_id: hidden_legs))

      where(id: transfers.select(:inflow_transaction_id))
        .or(where(id: transfers.select(:outflow_transaction_id)))
        .or(where(transfer_id: transfers.select(:id)))
    }
  end

  # The names Sure gives a transfer's legs and fees, which end in the other
  # account's name as it was then: "Transfer to Savings", "Payment from
  # Checking", "Transfer fee — Transfer to Savings".
  GENERATED_TRANSFER_NAME = /\A((?:Transfer fee — )?(?:Transfer|Payment) (?:to|from) ).+\z/

  def transfer
    transfer_as_inflow || transfer_as_outflow
  end

  # The account on the other side of this transfer leg; nil for any other
  # transaction.
  def counterpart_account
    if transfer_as_outflow
      transfer_as_outflow.to_account
    elsif transfer_as_inflow
      transfer_as_inflow.from_account
    end
  end

  # The entry's name as read by someone who can open only the accounts in
  # +accessible_account_ids+. A transfer leg or fee is usually named after the
  # account on the other side, so where that account is not theirs to open its
  # name is replaced, in the stored name or in the shape Sure gave it. The
  # stored name stays as it is for everyone who can open both accounts.
  def name_for(accessible_account_ids)
    name = entry.name
    # Confirmed legs carry a transfer kind and fees a transfer_id; checking
    # those first keeps other transactions free of the lookups below.
    return name unless transfer? || transfer_id

    hidden_account = name_counterpart_account
    return name if hidden_account.nil? || accessible_account_ids.include?(hidden_account.id)

    placeholder = I18n.t("transfer.hidden_account")
    if name.include?(hidden_account.name)
      name.gsub(hidden_account.name, placeholder)
    elsif (generated = GENERATED_TRANSFER_NAME.match(name))
      "#{generated[1]}#{placeholder}"
    else
      name
    end
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
    # The account a leg's or fee's name refers to. A fee belongs to its
    # transfer through transfer_id (Transaction's own #transfer is the leg's),
    # and sits in one of the transfer's two accounts.
    def name_counterpart_account
      return counterpart_account unless transfer_id

      fee_transfer = association(:transfer).reader
      [ fee_transfer&.from_account, fee_transfer&.to_account ].compact.find { |account| account.id != entry.account_id }
    end

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
