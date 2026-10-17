class PlaidAccount::Liabilities::CreditProcessor
  def initialize(plaid_account)
    @plaid_account = plaid_account
  end

  def process
    return unless credit_data.present?

    import_adapter.update_accountable_attributes(
      attributes: {
        minimum_payment: credit_data.dig("minimum_payment_amount"),
        apr: credit_data.dig("aprs", 0, "apr_percentage")
      }.merge(statement_cycle_attributes),
      source: "plaid"
    )
  end

  private
    attr_reader :plaid_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      plaid_account.current_account
    end

    def credit_data
      plaid_account.raw_liabilities_payload["credit"]
    end

    # When the card's statements close and fall due, which is the pair of days
    # of the month that lets us work out which charge sits on which statement.
    # Plaid reports them as the dates of the last statement issued and the next
    # payment due; only the day of the month survives that, and only the day is
    # what the cycle is.
    #
    # Filled in only where the card has not already been told. These are the two
    # numbers on a card a user is most likely to correct by hand after reading
    # the issuer's own letter, and a sync that quietly reasserts Plaid's value
    # over that correction would lose it on the next run.
    def statement_cycle_attributes
      {
        statement_close_day: day_of_month(credit_data["last_statement_issue_date"]),
        due_day: day_of_month(credit_data["next_payment_due_date"])
      }.select { |attribute, day| day.present? && account.accountable.public_send(attribute).blank? }
    end

    def day_of_month(raw_date)
      return nil if raw_date.blank?

      Date.parse(raw_date.to_s).day
    rescue Date::Error
      # An unparseable date is no reason to fail a sync over: everything else
      # in the payload is still worth taking.
      nil
    end
end
