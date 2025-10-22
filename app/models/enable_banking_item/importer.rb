class EnableBankingItem::Importer
  def initialize(enable_banking_item, enable_banking_provider:)
    @enable_banking_item = enable_banking_item
    @enable_banking_provider = enable_banking_provider
  end

  def import
    fetch_and_import_accounts_data
  rescue Provider::EnableBanking::Error => e
    handle_enable_banking_error(e)
  end

  private
    attr_reader :enable_banking_item, :enable_banking_provider

    # All errors that should halt the import should be re-raised after handling
    # These errors will propagate up to the Sync record and mark it as failed.
    def handle_enable_banking_error(error)
      error_body = JSON.parse(error.details) rescue {}
      code = (error_body["code"] || error_body.dig("error", "code")).to_i
      case code
      when 401, 403
        enable_banking_item.update!(status: :requires_update)
      else
        raise error
      end
    end

    def fetch_and_import_accounts_data
      payload = JSON.parse(enable_banking_item.raw_payload) rescue nil
      unless payload.is_a?(Hash)
        Rails.logger.warn("EnableBankingItem::Importer: invalid JSON payload for item ID #{enable_banking_item.id}")
        return
      end
      accounts = payload["accounts"]
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
        transactions = enable_banking_provider.get_transactions(account_id, enable_banking_account.new_record?)

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
      if raw_account["product"].present?
        return raw_account["product"]
      end
      if raw_account.dig("account_id", "iban").present?
        return raw_account.dig("account_id", "iban")
      end
      identification = raw_account.dig("account_id", "other", "identification")
      identification
    end
end
