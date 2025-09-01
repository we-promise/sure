class SimplefinItem::Importer
  attr_reader :simplefin_item, :simplefin_provider

  def initialize(simplefin_item, simplefin_provider:)
    @simplefin_item = simplefin_item
    @simplefin_provider = simplefin_provider
  end

  def import
    if simplefin_item.last_synced_at.nil?
      # First sync - use chunked approach to get full history
      import_with_chunked_history
    else
      # Regular sync - use single request with buffer
      import_regular_sync
    end
  end

  private

    def import_with_chunked_history
      # For initial sync, use user-selected start date or default lookback
      chunk_size_days = initial_sync_lookback_period
      current_end_date = Time.current
      
      # Use user-selected sync_start_date if available, otherwise use default lookback
      user_start_date = simplefin_item.sync_start_date
      target_start_date = user_start_date ? user_start_date.beginning_of_day : chunk_size_days.days.ago
      
      total_accounts_imported = 0
      chunk_count = 0

      Rails.logger.info "SimpleFin chunked sync: syncing from #{target_start_date.strftime('%Y-%m-%d')} to #{current_end_date.strftime('%Y-%m-%d')}"

      loop do
        chunk_count += 1
        start_date = current_end_date - chunk_size_days.days
        
        # Don't go back further than the target start date
        if start_date < target_start_date
          start_date = target_start_date
        end
        
        Rails.logger.info "SimpleFin chunked sync: fetching chunk #{chunk_count} (#{start_date.strftime('%Y-%m-%d')} to #{current_end_date.strftime('%Y-%m-%d')})"

        accounts_data = fetch_accounts_data(start_date: start_date, end_date: current_end_date)
        return if accounts_data.nil? # Error already handled

        # Store raw payload on first chunk only
        if chunk_count == 1
          simplefin_item.upsert_simplefin_snapshot!(accounts_data)
        end

        # Import accounts and transactions for this chunk
        accounts_data[:accounts]&.each do |account_data|
          import_account(account_data)
        end
        total_accounts_imported += accounts_data[:accounts]&.size || 0

        # Stop if we've reached our target start date
        if start_date <= target_start_date
          Rails.logger.info "SimpleFin chunked sync: reached target start date, stopping"
          break
        end

        # Continue to next chunk
        current_end_date = start_date
      end

      Rails.logger.info "SimpleFin chunked sync completed: #{chunk_count} chunks processed, #{total_accounts_imported} account records imported"
    end

    def import_regular_sync
      start_date = determine_sync_start_date
      
      accounts_data = fetch_accounts_data(start_date: start_date)
      return if accounts_data.nil? # Error already handled

      # Store raw payload
      simplefin_item.upsert_simplefin_snapshot!(accounts_data)

      # Import accounts
      accounts_data[:accounts]&.each do |account_data|
        import_account(account_data)
      end
    end

    def fetch_accounts_data(start_date:, end_date: nil)
      begin
        accounts_data = simplefin_provider.get_accounts(
          simplefin_item.access_url,
          start_date: start_date,
          end_date: end_date
        )
      rescue Provider::Simplefin::SimplefinError => e
        # Handle authentication errors by marking item as requiring update
        if e.error_type == :access_forbidden
          simplefin_item.update!(status: :requires_update)
          raise e
        else
          raise e
        end
      end

      # Handle errors if present in response
      if accounts_data[:errors] && accounts_data[:errors].any?
        handle_errors(accounts_data[:errors])
        return nil
      end

      accounts_data
    end

    def determine_sync_start_date
      # For the first sync, get only a limited amount of data to avoid SimpleFin API limits
      # SimpleFin requires a start_date parameter - without it, only returns recent transactions
      unless simplefin_item.last_synced_at
        return initial_sync_lookback_period.days.ago
      end

      # For subsequent syncs, fetch from last sync date with a buffer
      # Use buffer to ensure we don't miss any late-posting transactions
      simplefin_item.last_synced_at - sync_buffer_period.days
    end

    def import_account(account_data)
      account_id = account_data[:id]

      # Validate required account_id to prevent duplicate creation
      return if account_id.blank?

      simplefin_account = simplefin_item.simplefin_accounts.find_or_initialize_by(
        account_id: account_id
      )

      # Store transactions separately from account data to avoid overwriting
      transactions = account_data[:transactions]

      # Update all attributes; only update transactions if present to avoid wiping prior data
      attrs = {
        name: account_data[:name],
        account_type: account_data["type"] || account_data[:type] || "unknown",
        currency: account_data[:currency] || "USD",
        current_balance: account_data[:balance],
        available_balance: account_data[:"available-balance"],
        balance_date: account_data[:"balance-date"],
        raw_payload: account_data,
        org_data: account_data[:org]
      }
      attrs[:raw_transactions_payload] = transactions unless transactions.nil?
      simplefin_account.assign_attributes(attrs)

      # Final validation before save to prevent duplicates
      if simplefin_account.account_id.blank?
        simplefin_account.account_id = account_id
      end

      simplefin_account.save!
    end


    def handle_errors(errors)
      error_messages = errors.map { |error| error.is_a?(String) ? error : (error[:description] || error[:message]) }.join(", ")

      # Mark item as requiring update for authentication-related errors
      needs_update = errors.any? do |error|
        if error.is_a?(String)
          error.downcase.include?("reauthenticate") || error.downcase.include?("authentication")
        else
          error[:code] == "auth_failure" || error[:code] == "token_expired" ||
          error[:type] == "authentication_error"
        end
      end

      if needs_update
        simplefin_item.update!(status: :requires_update)
      end

      raise Provider::Simplefin::SimplefinError.new(
        "SimpleFin API errors: #{error_messages}",
        :api_error
      )
    end

    def initial_sync_lookback_period
      # Default to 7 days for initial sync to avoid API limits
      # Can be configured via Rails.application.config if needed
      Rails.application.config.simplefin&.dig(:initial_sync_lookback_days) || 7
    end

    def sync_buffer_period
      # Default to 7 days buffer for subsequent syncs
      # Can be configured via Rails.application.config if needed  
      Rails.application.config.simplefin&.dig(:sync_buffer_days) || 7
    end
end
