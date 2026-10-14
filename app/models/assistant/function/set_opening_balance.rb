# frozen_string_literal: true

# SetOpeningBalance — sets a manual account's opening balance and/or the date
# it applies from, through Account#set_opening_anchor_balance (the same
# Account::OpeningBalanceManager path used when an account is created).
#
# The date must be before the account's oldest entry. The response says what
# happens to the current balance: a later balance update (reconciliation)
# fixes it, otherwise it moves by the same amount as the opening balance.
class Assistant::Function::SetOpeningBalance < Assistant::Function
  class << self
    def name
      "set_opening_balance"
    end

    def description
      <<~INSTRUCTIONS
        Sets the opening balance of a manual account (one not synced from a
        bank or other provider) and, optionally, the date it applies from.
        Use it when an account's history starts on the wrong date or from the
        wrong amount, e.g. a loan whose first repayment predates its opening
        balance, or a savings account that opened at zero.

        balance uses the same sign convention as get_accounts (a loan's
        outstanding amount is positive). date must be before the account's
        oldest entry; omit it to keep the current opening date.

        The result says whether the current balance changes: if the account has
        a later balance update, only the history before it changes. Pass
        dry_run: true to see the effect without changing anything.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id balance],
      properties: {
        account_id: {
          type: "string",
          description: "Manual account ID from get_accounts."
        },
        balance: {
          type: "number",
          description: "Opening balance in the account's currency."
        },
        date: {
          type: "string",
          description: "Date the opening balance applies from (YYYY-MM-DD), before the account's oldest entry. Omit to keep the current date."
        },
        dry_run: {
          type: "boolean",
          description: "Describe the change without making it. Defaults to false."
        }
      }
    )
  end

  def call(params = {})
    account = find_account(params["account_id"])
    return error("not_found", "No account with id '#{params["account_id"]}' that you can write to.") unless account
    return error("linked_account", "#{account.name} is synced from a provider, which manages its balances. Only manual accounts have an editable opening balance.") if account.linked?

    balance = parse_balance(params["balance"])
    return error("invalid_balance", "balance must be a number.") unless balance

    date = nil
    # A supplied blank date is an error, not "keep the current date".
    unless params["date"].nil?
      date = parse_date(params["date"])
      return error("invalid_date", "date must be YYYY-MM-DD.") unless date
    end

    manager = Account::OpeningBalanceManager.new(account)
    if (message = manager.date_error(date))
      return error("invalid_date", "#{message} (#{manager.oldest_entry_date}).", oldest_entry_date: manager.oldest_entry_date)
    end

    before = opening(account, manager)
    new_date = date || before&.dig(:date) || manager.default_date
    after = { date: new_date, balance: balance.to_s }
    effect = current_balance_effect(account, new_date, balance - (before ? BigDecimal(before[:balance]) : 0))

    if ActiveModel::Type::Boolean.new.cast(params["dry_run"])
      return { success: true, dry_run: true, account: account_summary(account), before: before, after: after, current_balance: effect }
    end

    result = account.set_opening_anchor_balance(balance: balance, date: date)
    return error("update_failed", result.error) unless result.success?

    {
      success: true,
      changed: result.changes_made?,
      account: account_summary(account),
      before: before,
      after: after,
      current_balance: effect
    }
  end

  private
    def find_account(id)
      return nil unless valid_uuid?(id)

      family.accounts.visible.writable_by(user).find_by(id: id)
    end

    def opening(account, manager)
      return nil unless manager.has_opening_anchor?

      { date: manager.opening_date, balance: manager.opening_balance.to_s }
    end

    # Reconciliations after the opening date pin the balance from that point on.
    def current_balance_effect(account, new_date, delta)
      pinned_by = account.entries.valuations
        .joins("JOIN valuations ON valuations.id = entries.entryable_id")
        .where(valuations: { kind: "reconciliation" })
        .where("entries.date > ?", new_date)
        .minimum(:date)

      if pinned_by
        { changes: false, reason: "The balance update on #{pinned_by} fixes the balance from that date, so only the history before it changes." }
      elsif delta.zero?
        { changes: false, reason: "The opening balance amount is unchanged." }
      else
        { changes: true, by: delta.to_s, reason: "No later balance update, so the current balance moves by the same amount as the opening balance." }
      end
    end

    def account_summary(account)
      { id: account.id, name: account.name, currency: account.currency }
    end

    def parse_balance(value)
      return nil if value.nil? || value.is_a?(TrueClass) || value.is_a?(FalseClass)

      number = BigDecimal(value.to_s, exception: false)
      number if number&.finite?
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def error(key, message, **details)
      { success: false, error: key, message: message, **details }
    end
end
