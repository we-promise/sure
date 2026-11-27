# frozen_string_literal: true

# A Tricount account's row for what its member paid for an entry (whole or one
# part of it), and what dividing that payment works with: the tricount, the
# entry, the whole payment and its current parts.
class TricountAccount::PaymentSplit
  attr_reader :tricount_account, :entry, :ledger_entry

  # The split for a transaction row, or nil when the row isn't a Tricount
  # payment (a share, a settle-up's other side, another provider's row).
  def self.for(entry)
    return nil unless entry&.source == TricountAccount::Transactions::Processor::SOURCE

    uuid = entry.external_id.to_s.sub(TricountAccount::Transactions::Processor::PAID_LEG, "")
    return nil if uuid == entry.external_id.to_s || uuid.blank?

    tricount_account = TricountAccount.joins(:account_provider).find_by(account_providers: { account_id: entry.account_id })
    return nil unless tricount_account

    ledger_entry = tricount_account.ledger.active_entries.find { |candidate| candidate.uuid == uuid }
    return nil unless ledger_entry && ledger_entry.payer_uuid == tricount_account.member_uuid

    new(tricount_account, entry, ledger_entry)
  end

  def initialize(tricount_account, entry, ledger_entry)
    @tricount_account = tricount_account
    @entry = entry
    @ledger_entry = ledger_entry
  end

  def entry_uuid
    ledger_entry.uuid
  end

  def total
    Money.new(ledger_entry.amount.abs, currency)
  end

  # The whole payment as the split dialog and a part's row show it: signed
  # like the payment's rows (money into the tricount, what you paid, shown
  # positive), as the transaction split dialog shows its original amount.
  def display_total
    entry.amount.negative? ? total : -total
  end

  # The whole payment's name, "Dinner (you paid)", also from a part's row.
  def name
    key = entry.amount.positive? ? "received_name" : "paid_name"
    I18n.t("tricount_items.transactions.#{key}", description: ledger_entry.description.presence || tricount_account.name)
  end

  def date
    entry.date
  end

  def currency
    ledger_entry.currency.presence || tricount_account.currency
  end

  def scale
    ledger_entry.scale
  end

  # The current parts, as amount strings, or none when the payment is whole.
  def parts
    Array(tricount_account.paid_splits[entry_uuid])
  end

  def split?
    parts.any?
  end

  # Whether this row is one part of a split payment rather than the whole one.
  def part?
    entry.external_id.to_s.match(TricountAccount::Transactions::Processor::PAID_LEG)&.[](:part).present?
  end
end
