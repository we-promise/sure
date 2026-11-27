module SplitsHelper
  # Split amounts go in number inputs, which only take dot decimals whatever
  # the user's language, at the precision a split row can carry.
  def split_amount_input_value(amount, currency)
    number_with_precision(amount, precision: Transaction::ReceiptItemizer.amount_precision(currency), separator: ".", delimiter: "")
  end

  def split_amount_step(currency)
    split_amount_input_value(BigDecimal(10)**-Transaction::ReceiptItemizer.amount_precision(currency), currency)
  end

  # The editor's starting rows: one per row of a receipt proposal (in the
  # editor's sign convention), or a single blank row named like the entry.
  def split_editor_rows(entry, proposal)
    return [ { name: entry.name, amount: nil } ] unless proposal

    proposal.rows.map { |row| { name: row.name, amount: split_amount_input_value(-row.amount, entry.currency) } }
  end
end
