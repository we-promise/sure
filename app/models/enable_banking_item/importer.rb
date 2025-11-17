class EnableBankingItem::Importer
  attr_reader :enable_banking_item, :enable_banking_provider

  def initialize(enable_banking_item, enable_banking_provider:)
    @enable_banking_item = enable_banking_item
    @enable_banking_provider = enable_banking_provider
  end

  def import
    fetch_and_import_accounts_data
  end

  private

    def fetch_and_import_accounts_data
      accounts = JSON.parse(enable_banking_item.raw_payload).dig("accounts")
      unless accounts.is_a?(Array)
        Rails.logger.warn("EnableBankingItem::Importer: 'accounts' is not an Array in payload for item ID #{enable_banking_item.id}")
        return
      end

      accounts.each do |raw_account|
        account_id = raw_account["uid"]
        enable_banking_account = enable_banking_item.enable_banking_accounts.find_or_initialize_by(
          account_id: account_id
        )

        account_details = enable_banking_provider.get_account_details(account_id)
        transactions = enable_banking_provider.get_transactions(account_id, 30.days.ago.to_date.iso8601) # TODO: use different date

        raw_account["name"] = extract_account_name(account_details)
        raw_account["account_type"] = account_details["cash_account_type"]
        raw_account["balances"] = enable_banking_provider.get_current_available_balance(account_id)
        raw_account["transactions_data"] = transactions
        
        EnableBankingAccount::Importer.new(
          enable_banking_account,
          account_snapshot: raw_account
        ).import
      end
    end

    def extract_account_name(raw_account)
      if raw_account["name"].present?
        return raw_account["name"]
      end
      if raw_account.dig("account_id", "iban").present?
        return raw_account.dig("account_id", "iban")
      end
      identification = raw_account.dig("account_id", "other", "identification")
      return identification if identification
      nil
    end

end
