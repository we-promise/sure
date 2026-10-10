# frozen_string_literal: true

# MatchTransfer — links an existing transaction into a confirmed transfer, the
# same operation as the "Match transfer" dialog. Either pairs it with an
# existing opposite transaction, or creates the missing counterpart in a
# target account (the usual case for manual loan, mortgage and savings
# accounts that have no bank feed).
#
# Both accounts must be writable by the user. The data rules live in
# Transfer::Matcher.
class Assistant::Function::MatchTransfer < Assistant::Function
  include Assistant::Function::TransferMatchSupport

  class << self
    def name
      "match_transfer"
    end

    def description
      <<~INSTRUCTIONS
        Marks a transaction as a transfer between the user's own accounts, so it
        stops counting as income or spending and moves the other account's
        balance. Payments to loans and credit cards still count in budgets.

        Pass exactly one of:
        - counterpart_transaction_id: an existing transaction to pair with,
          from get_transfer_match_candidates.
        - target_account_id: an account (from get_accounts) with no matching
          transaction; a counterpart transaction is created there.

        Pass dry_run: true to see what would happen without changing anything.

        Returns already_linked (with the transfer id) if either transaction is
        already in a transfer. For a pending auto-match, reject it with
        review_transfer first. Matching the same pair again is a no-op.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[transaction_id],
      properties: {
        transaction_id: {
          type: "string",
          description: "Transaction ID from get_transactions."
        },
        counterpart_transaction_id: {
          type: "string",
          description: "Existing opposite transaction to pair with, from get_transfer_match_candidates. Omit when passing target_account_id."
        },
        target_account_id: {
          type: "string",
          description: "Account to create the counterpart transaction in, from get_accounts. Omit when passing counterpart_transaction_id."
        },
        dry_run: {
          type: "boolean",
          description: "Describe the change without making it. Defaults to false."
        }
      }
    )
  end

  def call(params = {})
    if params["counterpart_transaction_id"].present? == params["target_account_id"].present?
      return error("invalid_arguments", "Pass exactly one of counterpart_transaction_id or target_account_id.")
    end

    transaction = find_transaction(params["transaction_id"], writable: true)
    return error("not_found", "No transaction with id '#{params["transaction_id"]}' in an account you can write to.") unless transaction

    if params["counterpart_transaction_id"].present?
      counterpart = find_transaction(params["counterpart_transaction_id"], writable: true)
      return error("not_found", "No transaction with id '#{params["counterpart_transaction_id"]}' in an account you can write to.") unless counterpart
    else
      account = find_account(params["target_account_id"])
      return error("account_not_found", "No account with id '#{params["target_account_id"]}' that you can write to.") unless account
    end

    if (existing = transaction.transfer)
      return already_matched(existing, transaction) if same_match?(existing, transaction, counterpart, account)

      return error(
        "already_linked",
        existing.pending? ? "The transaction is in a pending auto-match. Reject it with review_transfer before matching it elsewhere." : "The transaction is already part of a transfer.",
        transfer: serialize_transfer(existing, from: transaction)
      )
    end

    if counterpart&.transfer
      return error("already_linked", "The counterpart transaction is already part of a transfer.", transfer: serialize_transfer(counterpart.transfer, from: counterpart))
    end

    dry_run = ActiveModel::Type::Boolean.new.cast(params["dry_run"]) || false
    matcher = Transfer::Matcher.new(transaction)
    transfer = counterpart ? matcher.match_with!(counterpart, dry_run:) : matcher.match_to_account!(account, dry_run:)

    return dry_run_result(transfer, transaction, account) if dry_run

    {
      success: true,
      created_counterpart: counterpart.nil?,
      transfer: transfer_result(transfer)
    }
  rescue Transfer::Matcher::Error => e
    error(e.code.to_s, e.message)
  end

  private
    def same_match?(transfer, transaction, counterpart, account)
      other = transfer.inflow_transaction_id == transaction.id ? transfer.outflow_transaction : transfer.inflow_transaction
      return false if transfer.pending? || other.nil?

      counterpart ? other.id == counterpart.id : other.entry.account_id == account.id
    end

    def already_matched(transfer, transaction)
      { success: true, already_matched: true, transfer: serialize_transfer(transfer, from: transaction) }
    end

    # The transfer is unsaved: a counterpart to be created has no id yet.
    def dry_run_result(transfer, transaction, account)
      counterpart = transfer.inflow_transaction == transaction ? transfer.outflow_transaction : transfer.inflow_transaction

      {
        success: true,
        dry_run: true,
        transaction: serialize_transaction(transaction),
        counterpart: account ? nil : serialize_transaction(counterpart),
        creates_counterpart_in: account && { account_id: account.id, account: account.name, name: counterpart.entry.name },
        outflow_kind: Transfer.kind_for_account(transfer.inflow_transaction.entry.account)
      }.compact
    end

    def transfer_result(transfer)
      {
        transfer_id: transfer.id,
        status: transfer.status,
        outflow: serialize_transaction(transfer.outflow_transaction.reload),
        inflow: serialize_transaction(transfer.inflow_transaction.reload)
      }
    end
end
