# The value step of the property setup wizard. What the property was bought
# for is its opening anchor ("Original purchase price") on the purchase date,
# as the generic account form does with its opening balance date.
# Saving again moves that one valuation rather than adding one.
class Property::PurchaseValue
  attr_reader :account

  # +date+ is the submitted purchase date; blank means the default.
  def initialize(account, date: nil)
    @account = account
    @submitted_date = date
  end

  # Raises Date::Error when the submitted date can't be parsed.
  def date
    @submitted_date.presence&.to_date || default_date
  end

  # Not in the future, and after the oldest date an entry may have.
  def valid_date?
    date > Entry.min_supported_date && date <= Date.current
  rescue Date::Error
    false
  end

  # The purchase valuation must come before any other value the draft
  # already has, so the default is the latest date that allows it, kept
  # within the range the field accepts.
  def default_date
    return account.opening_anchor_date if account.has_opening_anchor?

    oldest = Account::OpeningBalanceManager.new(account).oldest_entry_date
    latest = oldest ? [ oldest.prev_day, Date.current ].min : Date.current
    [ latest, Entry.min_supported_date + 1 ].max
  end

  # Returns the opening balance manager's result.
  def save(balance)
    result = Account::OpeningBalanceManager.new(account).set_opening_balance(balance: balance, date: date)
    return result unless result.success?

    # The amount was typed in the account's current currency, which a
    # resubmitted step may have changed.
    account.valuations.opening_anchor.first.entry.update!(currency: account.currency)
    account.update!(balance: balance)
    account.sync_later
    result
  end
end
