# Links an entry on the investment account to its other side in another
# account as a confirmed transfer, like Trade Republic does for settlements.
# Confirming sets the kinds: money into the portfolio counts as an investment
# contribution, money out of it as a funds movement.
module SharesightAccount::TransferLinking
  extend ActiveSupport::Concern

  private

    def link_transfer!(leg, other)
      leg_transaction = leg.entryable
      other_transaction = other.entryable
      return false unless leg_transaction.is_a?(Transaction) && other_transaction.is_a?(Transaction)

      existing = leg_transaction.transfer
      return true if existing && [ existing.inflow_transaction_id, existing.outflow_transaction_id ].include?(other_transaction.id)
      # Already linked to something else (by you or Sure's matching), so leave it.
      return false if existing || other_transaction.transfer

      inflow, outflow = leg.amount.negative? ? [ leg_transaction, other_transaction ] : [ other_transaction, leg_transaction ]
      # If you unlinked this pair before, it stays unlinked.
      return false if RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)

      Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed").confirm!
      true
    rescue ActiveRecord::RecordInvalid => e
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Sharesight couldn't link #{leg.external_id} to #{other.name} as a transfer: #{e.message}",
        source: "sharesight",
        family: @sharesight_account.sharesight_item.family,
        provider_key: "sharesight"
      )
      false
    end

    # Already part of a transfer with some account other than the portfolio's.
    def transferred_elsewhere?(entry, portfolio_account)
      transfer = entry.entryable.try(:transfer)
      return false unless transfer

      [ transfer.inflow_transaction, transfer.outflow_transaction ].none? { |transaction| transaction.entry.account_id == portfolio_account.id }
    end
end
