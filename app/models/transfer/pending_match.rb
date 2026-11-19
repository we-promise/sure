# A pending transfer match seen from one of its legs: the other leg, and how
# much of it a viewer may be shown. The other leg's account is named only to
# a viewer who can see it, and the transfer is linked only then, as its page
# needs access to both legs.
class Transfer::PendingMatch
  attr_reader :transaction, :transfer

  def initialize(transaction, visible_account_ids:)
    @transaction = transaction
    @transfer = transaction.transfer
    @visible_account_ids = visible_account_ids.to_set
  end

  def counterpart_entry
    (outflow_leg? ? transfer.inflow_transaction : transfer.outflow_transaction)&.entry
  end

  def counterpart_account
    outflow_leg? ? transfer.to_account : transfer.from_account
  end

  def counterpart_visible?
    account = counterpart_account
    account.present? && @visible_account_ids.include?(account.id)
  end

  # A leg whose kind already makes its row open the transfer needs no second
  # link to it.
  def links_to_transfer?
    counterpart_visible? && !transaction.transfer?
  end

  private
    def outflow_leg?
      transfer.outflow_transaction_id == transaction.id
    end
end
