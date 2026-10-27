class PlaidAccount::Importer
  def initialize(plaid_account, account_snapshot:)
    @plaid_account = plaid_account
    @account_snapshot = account_snapshot
  end

  def import
    import_account_info
    import_transactions if account_snapshot.transactions_data.present?
    import_investments if account_snapshot.investments_data.present?
    if account_snapshot.liabilities_data.present?
      import_liabilities
    elsif plaid_account.raw_liabilities_payload.present?
      clear_liabilities
    end
  end

  private
    attr_reader :plaid_account, :account_snapshot

    def import_account_info
      plaid_account.upsert_plaid_snapshot!(account_snapshot.account_data)
    end

    def import_transactions
      plaid_account.upsert_plaid_transactions_snapshot!(account_snapshot.transactions_data)
    end

    def import_investments
      plaid_account.upsert_plaid_holdings_snapshot!(account_snapshot.investments_data)
    end

    def import_liabilities
      plaid_account.upsert_plaid_liabilities_snapshot!(account_snapshot.liabilities_data)
    end

    # This sync fetched no liabilities, so a payload still stored is an earlier
    # sync's. Processed again, a variable loan would record its rate as a
    # change dated to this sync.
    def clear_liabilities
      plaid_account.upsert_plaid_liabilities_snapshot!({})
    end
end
