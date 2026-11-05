# frozen_string_literal: true

# Shared plumbing for the transfer-matching tools (get_transfer_match_candidates,
# match_transfer, review_transfer). Tool calls never pass through
# TransferMatchesController or TransfersController, so every lookup here
# re-applies their account-access scopes: reads resolve through accounts the
# user can see, writes through accounts the user can write to. Anything else
# resolves to nil, so a caller cannot tell "no access" from "does not exist".
module Assistant::Function::TransferMatchSupport
  private
    def find_transaction(id, writable:)
      return nil unless valid_uuid?(id)

      family.transactions
        .joins(entry: :account)
        .merge(writable ? Account.writable_by(user) : Account.accessible_by(user))
        .find_by(id: id)
    end

    def find_account(id)
      return nil unless valid_uuid?(id)

      family.accounts.visible.writable_by(user).find_by(id: id)
    end

    def accessible_account_ids
      @accessible_account_ids ||= family.accounts.accessible_by(user).pluck(:id).to_set
    end

    def serialize_transaction(transaction)
      entry = transaction.entry

      {
        transaction_id: transaction.id,
        account_id: entry.account_id,
        account: entry.account.name,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.abs.to_s,
        amount_formatted: format_money(entry.amount_money.abs),
        currency: entry.currency,
        direction: entry.amount.negative? ? "inflow" : "outflow",
        kind: transaction.kind
      }
    end

    # The counterpart is omitted when it sits in an account the user cannot
    # see, e.g. a transfer into another member's private account.
    def serialize_transfer(transfer, from:)
      other = transfer.inflow_transaction_id == from.id ? transfer.outflow_transaction : transfer.inflow_transaction

      {
        transfer_id: transfer.id,
        status: transfer.status,
        counterpart: (serialize_transaction(other) if other && accessible_account_ids.include?(other.entry.account_id))
      }.compact
    end

    def format_money(money)
      money.format
    rescue StandardError
      "#{money.amount} #{money.currency}"
    end

    def error(key, message, **details)
      { success: false, error: key, message: message, **details }
    end
end
