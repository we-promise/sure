# One transaction read from a bank alert email.
#
# +amount+ is always a positive magnitude and +direction+ says which way money
# moved; +entry_amount+ converts to Sure's sign convention (outflows positive).
# +account_identifier+ distinguishes accounts at the same institution (a masked
# account number, or the wallet currency for multi-currency wallets).
EmailAlert::ParsedAlert = Data.define(
  :parser_key,
  :institution_name,
  :account_identifier,
  :account_name,
  :currency,
  :amount,
  :direction,
  :occurred_at,
  :description,
  :reference,
  :balance,
  :category_hint,
  :details
) do
  def initialize(reference: nil, balance: nil, category_hint: nil, details: {}, **attrs)
    super
  end

  def debit? = direction == :debit
  def credit? = direction == :credit

  def entry_amount
    debit? ? amount : -amount
  end

  # Stable across re-deliveries of the same alert and distinct for the fee
  # alerts a bank sends alongside a transfer, which can share a reference.
  def external_id
    fingerprint = [
      account_identifier, direction, amount.to_s("F"), currency,
      occurred_at&.utc&.iso8601, reference, description
    ].join("|")
    "#{parser_key}_#{Digest::SHA256.hexdigest(fingerprint).first(32)}"
  end

  def to_h_for_storage
    to_h.merge(amount: amount.to_s("F"), balance: balance&.to_s("F"), occurred_at: occurred_at&.iso8601)
  end
end
