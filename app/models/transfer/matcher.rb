# Links an existing transaction into a confirmed transfer, either with an
# existing opposite transaction (one of Transaction#transfer_match_candidates)
# or with a new counterpart entry created in a target account.
#
# This is the same operation as TransferMatchesController#create and
# Rule::ActionExecutor::SetAsTransferOrPayment, which predate this class and
# still carry their own copies of it. Permission checks are the caller's job:
# this class enforces only the data rules.
class Transfer::Matcher
  class Error < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  # The manual match dialog's window. Transfer validation allows confirmed
  # transfers up to 30 days apart.
  DATE_WINDOW = 30

  attr_reader :transaction

  def initialize(transaction)
    @transaction = transaction
  end

  def candidates(date_window: DATE_WINDOW)
    filter = entry.amount.negative? ? { inflow_transaction_id: transaction.id } : { outflow_transaction_id: transaction.id }

    family.transfer_match_candidates(
      date_window: date_window,
      exchange_rate_tolerance: Family::AutoTransferMatchable.manual_match_exchange_rate_tolerance,
      **filter
    )
  end

  # With dry_run: true, runs every check and returns the unsaved transfer.
  def match_with!(counterpart, dry_run: false)
    ensure_matchable!(transaction)
    ensure_matchable!(counterpart)

    unless candidates.any? { |c| [ c.inflow_transaction_id, c.outflow_transaction_id ].include?(counterpart.id) }
      raise Error.new(:not_a_candidate, "The two transactions cannot form a transfer: they need opposite, matching amounts in different accounts of the same family, at most #{DATE_WINDOW} days apart.")
    end

    inflow, outflow = entry.amount.negative? ? [ transaction, counterpart ] : [ counterpart, transaction ]
    link!(inflow:, outflow:, dry_run:)
  end

  def match_to_account!(account, dry_run: false)
    ensure_matchable!(transaction)
    raise Error.new(:same_account, "The target account must differ from the transaction's account.") if account.id == entry.account_id
    raise Error.new(:account_not_found, "The target account must belong to the same family.") unless account.family_id == entry.account.family_id

    # Built in memory; saved together with the transfer by link!.
    counterpart = Transaction.new(
      entry: account.entries.build(
        amount: entry.amount * -1,
        currency: entry.currency,
        date: entry.date,
        name: "Transfer to #{entry.amount.negative? ? entry.account.name : account.name}",
        user_modified: true
      )
    )

    inflow, outflow = entry.amount.negative? ? [ transaction, counterpart ] : [ counterpart, transaction ]
    link!(inflow:, outflow:, dry_run:)
  end

  private
    def entry
      transaction.entry
    end

    def family
      entry.account.family
    end

    def ensure_matchable!(txn)
      txn_entry = txn.entry
      raise Error.new(:split_transaction, "Split transactions cannot be matched as transfers.") if txn_entry.split_parent? || txn_entry.split_child?
      raise Error.new(:excluded_transaction, "Excluded transactions cannot be matched as transfers.") if txn_entry.excluded?
      raise Error.new(:already_linked, "The transaction is already part of a transfer.") if txn.transfer.present?
    end

    def link!(inflow:, outflow:, dry_run:)
      transfer = Transfer.new(
        inflow_transaction: inflow,
        outflow_transaction: outflow,
        status: "confirmed",
        amount: outflow.entry.amount.abs
      )

      if dry_run
        raise Error.new(:invalid_transfer, transfer.errors.full_messages.to_sentence) unless transfer.valid?
        return transfer
      end

      Transfer.transaction do
        transfer.save!

        # Kinds follow the destination account, as in Transfer::Creator.
        destination_account = inflow.entry.account
        outflow_attrs = { kind: Transfer.kind_for_account(destination_account) }

        if outflow_attrs[:kind] == "investment_contribution"
          category = destination_account.family.investment_contributions_category
          outflow_attrs[:category] = category if category.present? && outflow.category_id.blank?
        end

        outflow.update!(outflow_attrs)
        inflow.update!(kind: "funds_movement")
      end

      transfer.sync_account_later
      transfer
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      raise Error.new(:invalid_transfer, e.message)
    end
end
