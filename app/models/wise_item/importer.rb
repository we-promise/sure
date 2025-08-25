class WiseItem::Importer
  attr_reader :wise_item, :wise_provider

  def initialize(wise_item, wise_provider:)
    @wise_item = wise_item
    @wise_provider = wise_provider
  end

  def import
    # First fetch profiles if we don't have them
    if wise_item.profile_id.blank?
      import_profiles
    end

    # Fetch accounts for all profiles
    [ wise_item.personal_profile_id, wise_item.business_profile_id ].compact.each do |profile_id|
      import_accounts_for_profile(profile_id)
    end
  end

  private

    def import_profiles
      profiles_data = wise_provider.get_profiles
      
      if profiles_data.empty?
        raise Provider::Wise::WiseError.new(
          "No profiles found for this Wise account",
          :no_profiles
        )
      end

      wise_item.upsert_wise_profiles_snapshot!(profiles_data)
    end

    def import_accounts_for_profile(profile_id)
      accounts_data = wise_provider.get_accounts(profile_id)
      
      # Store raw payload
      wise_item.upsert_wise_snapshot!(accounts_data)
      
      # Import each account (balance in Wise terminology)
      accounts_data.each do |account_data|
        import_account(profile_id, account_data)
      end
    end

    def import_account(profile_id, account_data)
      wise_account = wise_item.wise_accounts.find_or_initialize_by(
        account_id: account_data[:id].to_s
      )
      
      # Fetch transactions for this account
      transactions = fetch_transactions(profile_id, account_data[:id])
      
      # Update account snapshot
      wise_account.upsert_wise_snapshot!(account_data)
      
      # Save transactions separately
      if transactions && transactions.any?
        wise_account.update!(raw_transactions_payload: transactions)
      end
    end

    def fetch_transactions(profile_id, balance_id)
      begin
        # Determine start date based on sync history
        start_date = determine_sync_start_date
        
        response = wise_provider.get_transactions(
          profile_id,
          balance_id,
          start_date: start_date,
          end_date: Date.current
        )
        
        # Extract transactions from statement response
        response[:transactions] || []
      rescue Provider::Wise::WiseError => e
        Rails.logger.error("Failed to fetch Wise transactions for balance #{balance_id}: #{e.message}")
        # Don't fail the entire sync for transaction fetch failure
        []
      end
    end

    def determine_sync_start_date
      # For the first sync, get 90 days of history
      # For subsequent syncs, fetch from last sync date with a buffer
      if wise_item.last_synced_at
        wise_item.last_synced_at - 7.days
      else
        90.days.ago
      end
    end
end