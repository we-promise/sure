# Upserts the per-account raw payloads fetched from Plaid onto a
# Provider::Account row. Direct port of PlaidAccount::Importer; the only
# functional change is the target table (provider_accounts vs plaid_accounts)
# and the absence of denormalised columns (current_balance, available_balance,
# plaid_type, plaid_subtype, name, mask) — those live inside raw_payload now
# and are extracted via reader methods on Provider::Plaid::AccountReader.
class Provider::Plaid::AccountImporter
  def initialize(provider_account, account_snapshot:)
    @provider_account = provider_account
    @account_snapshot = account_snapshot
  end

  def import
    import_account_info
    import_transactions if account_snapshot.transactions_data.present?
    import_investments if account_snapshot.investments_data.present?
    import_liabilities if account_snapshot.liabilities_data.present?
  end

  private
    attr_reader :provider_account, :account_snapshot

    def import_account_info
      raw = account_snapshot.account_data
      provider_account.update!(
        external_name:    raw.name,
        external_type:    raw.type,
        external_subtype: raw.subtype,
        currency:         raw.balances&.iso_currency_code || raw.balances&.unofficial_currency_code,
        raw_payload:      raw.to_hash
      )
    end

    def import_transactions
      provider_account.update!(raw_transactions_payload: account_snapshot.transactions_data.to_h)
    end

    def import_investments
      provider_account.update!(raw_holdings_payload: account_snapshot.investments_data.to_h)
    end

    def import_liabilities
      provider_account.update!(raw_liabilities_payload: account_snapshot.liabilities_data.to_h)
    end
end
