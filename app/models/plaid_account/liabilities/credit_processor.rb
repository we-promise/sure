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
