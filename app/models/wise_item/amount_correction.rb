# frozen_string_literal: true

# A person's category, note or exclusion marks an entry user-modified, which
# keeps Account::ProviderImportAdapter off it, but it does not make Wise's
# amount theirs. So a later sync's amount (a sign or currency an older build
# got wrong, a split payment's part) still reaches such an entry, unless the
# person changed the amount or currency themselves (they are locked), an
# import owns the entry, they reconciled or split it, or it sits in a
# transfer, whose other leg would no longer match.
module WiseItem::AmountCorrection
  # entry: what the adapter returned for a Wise row that books amount in
  # currency. Returns the entry.
  def self.apply(entry, amount:, currency:)
    return entry unless entry.is_a?(Entry) && entry.persisted? && entry.protected_from_sync?
    return entry if entry.amount == amount.to_d && entry.currency == currency
    return entry unless correctable?(entry)

    entry.update!(amount: amount, currency: currency)
    entry
  end

  def self.correctable?(entry)
    transaction = entry.entryable
    return false unless transaction.is_a?(Transaction)
    return false if entry.import_locked? || entry.locked?(:amount) || entry.locked?(:currency) || entry.reconciled_at.present?

    !entry.split_parent? && transaction.transfer_id.nil? && transaction.transfer_as_inflow.nil? && transaction.transfer_as_outflow.nil?
  end
  private_class_method :correctable?
end
