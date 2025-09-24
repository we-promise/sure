class BankConnection::Importer
  attr_reader :bank_connection, :bank_provider, :mapper

  DEFAULT_FIRST_SYNC_DAYS = 90
  SUBSEQUENT_SYNC_BUFFER_DAYS = 7

  def initialize(bank_connection, bank_provider:)
    @bank_connection = bank_connection
    @bank_provider = bank_provider
    @mapper = bank_connection.bank_mapper
  end

  def import
    accounts_payload = bank_provider.list_accounts

    # Store raw payload for debugging/traceability
    bank_connection.upsert_bank_snapshot!(accounts_payload)

    # Upsert each external account and fetch transactions
    Array(accounts_payload).each do |provider_account|
      import_account(provider_account)
    end
  end

  private

    def import_account(provider_account)
      normalized = mapper.normalize_account(provider_account)

      ext = bank_connection.bank_external_accounts.find_or_initialize_by(
        provider_account_id: normalized[:provider_account_id].to_s
      )

      # Update snapshot from normalized data
      ext.upsert_bank_snapshot!(normalized)

      # Fetch transactions and store raw payloads (provider-native)
      transactions = fetch_transactions_for(normalized[:provider_account_id])
      if transactions.present?
        ext.update!(raw_transactions_payload: transactions)
      end
    end

    def fetch_transactions_for(provider_account_id)
      start_date = determine_sync_start_date
      end_date = Date.current
      bank_provider.list_transactions(
        account_id: provider_account_id,
        start_date: start_date,
        end_date: end_date
      )
    rescue => e
      Rails.logger.error("Failed to fetch transactions for #{provider_account_id}: #{e.message}")
      []
    end

    def determine_sync_start_date
      if bank_connection.last_synced_at
        bank_connection.last_synced_at - SUBSEQUENT_SYNC_BUFFER_DAYS.days
      else
        DEFAULT_FIRST_SYNC_DAYS.days.ago
      end
    end
end

