# frozen_string_literal: true

# Anchors the linked account's balance to the latest balance an alert reported.
# Transactions are imported per message (EmailAlertMessage::Processor) before
# this runs, so the anchor is judged against the complete imported ledger.
class EmailAlertAccount::Processor
  attr_reader :email_alert_account

  def initialize(email_alert_account)
    @email_alert_account = email_alert_account
  end

  def process
    account = email_alert_account.current_account
    return unless account

    balance = email_alert_account.current_balance
    if balance
      balance = -balance if account.accountable_type.in?([ "CreditCard", "Loan" ])
      account.set_current_balance(balance, date: balance_date(account), schedule_sync: false)
    end

    account.broadcast_sync_complete
    { balance_anchored: balance.present? }
  end

  private

    def balance_date(account)
      as_of = email_alert_account.balance_as_of
      return nil unless as_of

      as_of.in_time_zone(account.family.timezone.presence || "UTC").to_date
    end
end
