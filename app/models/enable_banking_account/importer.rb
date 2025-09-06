class EnableBankingAccount::Importer
  def initialize(enable_banking_account, account_snapshot:)
    @enable_banking_account = enable_banking_account
    @account_snapshot = account_snapshot
  end

  def import
    import_account_info
    import_transactions if account_snapshot["transactions_data"].present?
  end

  private
    attr_reader :enable_banking_account, :account_snapshot

    def import_account_info
      enable_banking_account.upsert_enable_banking_snapshot!(account_snapshot)
    end

    def import_transactions
      enable_banking_account.upsert_enable_banking_transactions_snapshot!(account_snapshot["transactions_data"])
    end
end
