require "set"
class SimplefinItem::Importer
  class RateLimitedError < StandardError; end
  attr_reader :simplefin_item, :simplefin_provider, :sync

  def initialize(simplefin_item, simplefin_provider:, sync: nil)
    @simplefin_item = simplefin_item
    @simplefin_provider = simplefin_provider
    @sync = sync
    @enqueued_holdings_job_ids = Set.new
  end

  def import
    Rails.logger.info "SimplefinItem::Importer - Starting import for item #{simplefin_item.id}"
    Rails.logger.info "SimplefinItem::Importer - last_synced_at: #{simplefin_item.last_synced_at.inspect}"
    Rails.logger.info "SimplefinItem::Importer - sync_start_date: #{simplefin_item.sync_start_date.inspect}"

    begin
      if simplefin_item.last_synced_at.nil?
        # First sync - use chunked approach to get full history
        Rails.logger.info "SimplefinItem::Importer - Using chunked history import"
        import_with_chunked_history
      else
        # Regular sync - use single request with buffer
        Rails.logger.info "SimplefinItem::Importer - Using regular sync"
        import_regular_sync
      end
    rescue RateLimitedError => e
      stats["rate_limited"] = true
      stats["rate_limited_at"] = Time.current.iso8601
      persist_stats!
      raise e
    end
  end

  # Balances-only import: discover accounts and update account balances without transactions/holdings
  def import_balances_only
    Rails.logger.info "SimplefinItem::Importer - Balances-only import for item #{simplefin_item.id}"
    stats["balances_only"] = true

    # Fetch accounts without date filters
    accounts_data = fetch_accounts_data(start_date: nil)
    return if accounts_data.nil?

    # Store snapshot for observability
    simplefin_item.upsert_simplefin_snapshot!(accounts_data)

    # Update counts (set to discovered for this run rather than accumulating)
    discovered = accounts_data[:accounts]&.size.to_i
    stats["total_accounts"] = discovered
    persist_stats!

    # Upsert SimpleFin accounts minimal attributes and update linked Account balances
    accounts_data[:accounts].to_a.each do |account_data|
      begin
        import_account_minimal_and_balance(account_data)
      rescue => e
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        cat = classify_error(e)
        register_error(message: e.message, category: cat, account_id: account_data[:id], name: account_data[:name])
      ensure
        persist_stats!
      end
    end
  end

  private

    # Minimal upsert and balance update for balances-only mode
    def import_account_minimal_and_balance(account_data)
      account_id = account_data[:id].to_s
      return if account_id.blank?

      sfa = simplefin_item.simplefin_accounts.find_or_initialize_by(account_id: account_id)
      sfa.assign_attributes(
        name: account_data[:name],
        account_type: (account_data["type"].presence || account_data[:type].presence || sfa.account_type.presence || "unknown"),
        currency: (account_data[:currency].presence || account_data["currency"].presence || sfa.currency.presence || sfa.current_account&.currency.presence || simplefin_item.family&.currency.presence || "USD"),
        current_balance: account_data[:balance],
        available_balance: account_data[:"available-balance"],
        balance_date: (account_data["balance-date"] || account_data[:"balance-date"]),
        raw_payload: account_data,
        org_data: account_data[:org]
      )
      begin
        sfa.save!
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Surface a friendly duplicate/validation signal in sync stats and continue
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        msg = e.message.to_s
        if msg.downcase.include?("already been taken") || msg.downcase.include?("unique")
          msg = "Duplicate upstream account detected for SimpleFin (account_id=#{account_id}). Try relinking to an existing manual account."
        end
        register_error(message: msg, category: "other", account_id: account_id, name: account_data[:name])
        persist_stats!
        return
      end
      # In pre-prompt balances-only discovery, do NOT auto-create provider-linked accounts.
      # Only update balance for already-linked accounts (if any), to avoid creating duplicates in setup.
      if (acct = sfa.current_account)
        adapter = Account::ProviderImportAdapter.new(acct)
        adapter.update_balance(
          balance: account_data[:balance],
          cash_balance: account_data[:"available-balance"],
          source: "simplefin"
        )
      end
    end
    def stats
      @stats ||= {}
    end

    # Heuristics to set a SimpleFIN account inactive when upstream indicates closure/hidden
    # or when we repeatedly observe zero balances and zero holdings. This should not block
    # import and only sets a flag and suggestion via sync stats.
    def update_inactive_state(simplefin_account, account_data)
      payload = (account_data || {}).with_indifferent_access
      raw = (simplefin_account.raw_payload || {}).with_indifferent_access

      # Flags from payloads
      closed = [ payload[:closed], payload[:hidden], payload.dig(:extra, :closed), raw[:closed], raw[:hidden] ].compact.any? { |v| v == true || v.to_s == "true" }

      balance = payload[:balance]
      avail = payload[:"available-balance"]
      holdings = payload[:holdings]
      amounts = [ balance, avail ].compact
      zeroish_balance = amounts.any? && amounts.all? { |x| x.to_d.zero? rescue false }
      no_holdings = !(holdings.is_a?(Array) && holdings.any?)

      stats["zero_runs"] ||= {}
      stats["inactive"] ||= {}
      key = simplefin_account.account_id.presence || simplefin_account.id
      key = key.to_s
      # Ensure key exists and defaults to false (so tests don't read nil)
      stats["inactive"][key] = false unless stats["inactive"].key?(key)

      if closed
        stats["inactive"][key] = true
        stats["hints"] = Array(stats["hints"]) + [ "Some accounts appear closed/hidden upstream. You can relink or hide them." ]
        return
      end

      if zeroish_balance && no_holdings
        stats["zero_runs"][key] = stats["zero_runs"][key].to_i + 1
        # Cap to avoid unbounded growth
        stats["zero_runs"][key] = [ stats["zero_runs"][key], 10 ].min
      else
        stats["zero_runs"][key] = 0
        stats["inactive"][key] = false
      end

      if stats["zero_runs"][key].to_i >= 3
        stats["inactive"][key] = true
        stats["hints"] = Array(stats["hints"]) + [ "One or more accounts show no balance/holdings for multiple syncs — consider relinking or marking inactive." ]
      end
    end

    # Track seen error fingerprints during a single importer run to avoid double counting
    def seen_errors
      @seen_errors ||= Set.new
    end

    # Register an error into stats with de-duplication and bucketing
    def register_error(message:, category:, account_id: nil, name: nil)
      msg = message.to_s.strip
      cat = (category.presence || "other").to_s
      fp = [ account_id.to_s.presence, cat, msg ].compact.join("|")
      first_time = !seen_errors.include?(fp)
      seen_errors.add(fp)

      if first_time
        Rails.logger.warn(
          "SimpleFin sync error (unique this run): category=#{cat} account_id=#{account_id.inspect} name=#{name.inspect} msg=#{msg}"
        )
        # Emit an instrumentation event for observability dashboards
        ActiveSupport::Notifications.instrument(
          "simplefin.error",
          item_id: simplefin_item.id,
          account_id: account_id,
          account_name: name,
          category: cat,
          message: msg
        )
      else
        # Keep logs tame; don't spam on repeats in the same run
      end

      stats["errors"] ||= []
      buckets = stats["error_buckets"] ||= { "auth" => 0, "api" => 0, "network" => 0, "other" => 0 }
      if first_time
        stats["total_errors"] = stats.fetch("total_errors", 0) + 1
        buckets[cat] = buckets.fetch(cat, 0) + 1
      end

      # Maintain a small rolling sample (not de-duped so users can see most recent context)
      stats["errors"] << { account_id: account_id, name: name, message: msg, category: cat }
      stats["errors"] = stats["errors"].last(5)
      persist_stats!
    end

    def persist_stats!
      return unless sync && sync.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged) # avoid callbacks/validations during tight loops
    end

    def import_with_chunked_history
      # SimpleFin's actual limit is 60 days (not 365 as documented)
      # Use 60-day chunks to stay within limits
      chunk_size_days = 60
      max_requests = 22
      current_end_date = Time.current

      # Use user-selected sync_start_date if available, otherwise use default lookback
      user_start_date = simplefin_item.sync_start_date
      default_start_date = initial_sync_lookback_period.days.ago
      target_start_date = user_start_date ? user_start_date.beginning_of_day : default_start_date

      # Enforce maximum 3-year lookback to respect SimpleFin's actual 60-day limit per request
      # With 22 requests max: 60 days × 22 = 1,320 days = 3.6 years, so 3 years is safe
      max_lookback_date = 3.years.ago.beginning_of_day
      if target_start_date < max_lookback_date
        Rails.logger.info "SimpleFin: Limiting sync start date from #{target_start_date.strftime('%Y-%m-%d')} to #{max_lookback_date.strftime('%Y-%m-%d')} due to rate limits"
        target_start_date = max_lookback_date
      end

      # Pre-step: Unbounded discovery to ensure we see all accounts even if the
      # chunked window would otherwise filter out newly added, inactive accounts.
      perform_account_discovery

      total_accounts_imported = 0
      chunk_count = 0

      Rails.logger.info "SimpleFin chunked sync: syncing from #{target_start_date.strftime('%Y-%m-%d')} to #{current_end_date.strftime('%Y-%m-%d')}"

      # Walk backwards from current_end_date in proper chunks
      chunk_end_date = current_end_date

      while chunk_count < max_requests && chunk_end_date > target_start_date
        chunk_count += 1

        # Calculate chunk start date - always use exactly chunk_size_days to stay within limits
        chunk_start_date = chunk_end_date - chunk_size_days.days

        # Don't go back further than the target start date
        if chunk_start_date < target_start_date
          chunk_start_date = target_start_date
        end

        # Verify we're within SimpleFin's limits
        actual_days = (chunk_end_date.to_date - chunk_start_date.to_date).to_i
        if actual_days > 365
          Rails.logger.error "SimpleFin: Chunk exceeds 365 days (#{actual_days} days). This should not happen."
          chunk_start_date = chunk_end_date - 365.days
        end

        Rails.logger.info "SimpleFin chunked sync: fetching chunk #{chunk_count}/#{max_requests} (#{chunk_start_date.strftime('%Y-%m-%d')} to #{chunk_end_date.strftime('%Y-%m-%d')}) - #{actual_days} days"

        accounts_data = fetch_accounts_data(start_date: chunk_start_date, end_date: chunk_end_date)
        return if accounts_data.nil? # Error already handled

        # Store raw payload on first chunk only
        if chunk_count == 1
          simplefin_item.upsert_simplefin_snapshot!(accounts_data)
        end

        # Tally accounts returned for stats
        chunk_accounts = accounts_data[:accounts]&.size.to_i
        total_accounts_imported += chunk_accounts
        # Treat total as max unique accounts seen this run, not per-chunk accumulation
        stats["total_accounts"] = [ stats["total_accounts"].to_i, chunk_accounts ].max

        # Import accounts and transactions for this chunk with per-account error skipping
        accounts_data[:accounts]&.each do |account_data|
          begin
            import_account(account_data)
          rescue => e
            stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
            # Collect lightweight error info for UI stats
            cat = classify_error(e)
            begin
              register_error(message: e.message.to_s, category: cat, account_id: account_data[:id], name: account_data[:name])
            rescue
              # no-op if account_data is missing keys
            end
            Rails.logger.warn("SimpleFin: Skipping account due to error: #{e.class} - #{e.message}")
          ensure
            persist_stats!
          end
        end

        # Stop if we've reached our target start date
        if chunk_start_date <= target_start_date
          Rails.logger.info "SimpleFin chunked sync: reached target start date, stopping"
          break
        end

        # Continue to next chunk - move the end date backwards
        chunk_end_date = chunk_start_date
      end

      Rails.logger.info "SimpleFin chunked sync completed: #{chunk_count} chunks processed, #{total_accounts_imported} account records imported"
    end

    def import_regular_sync
      perform_account_discovery

      # Step 2: Fetch transactions/holdings using the regular window.
      start_date = determine_sync_start_date
      accounts_data = fetch_accounts_data(start_date: start_date, pending: true)
      return if accounts_data.nil? # Error already handled

      # Store raw payload
      simplefin_item.upsert_simplefin_snapshot!(accounts_data)

      # Tally accounts for stats
      count = accounts_data[:accounts]&.size.to_i
      # Treat total as max unique accounts seen this run, not accumulation
      stats["total_accounts"] = [ stats["total_accounts"].to_i, count ].max

      # Import accounts (merges transactions/holdings into existing rows), skipping failures per-account
      accounts_data[:accounts]&.each do |account_data|
        begin
          import_account(account_data)
        rescue => e
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          cat = classify_error(e)
          begin
            register_error(message: e.message.to_s, category: cat, account_id: account_data[:id], name: account_data[:name])
          rescue
            # no-op if account_data is missing keys
          end
          Rails.logger.warn("SimpleFin: Skipping account during regular sync due to error: #{e.class} - #{e.message}")
        ensure
          persist_stats!
        end
      end
    end

    #
    # Performs discovery of accounts in an unbounded way so providers that
    # filter by date windows cannot hide newly created upstream accounts.
    #
    # Steps:
    # - Request `/accounts` without dates; count results
    # - If zero, retry with `pending: true` (some bridges only reveal new/pending)
    # - If any accounts are returned, upsert a snapshot and import each account
    #
    # Returns nothing; side-effects are snapshot + account upserts.
    def perform_account_discovery
      discovery_data = fetch_accounts_data(start_date: nil)
      discovered_count = discovery_data&.dig(:accounts)&.size.to_i
      Rails.logger.info "SimpleFin discovery (no params) returned #{discovered_count} accounts"

      if discovered_count.zero?
        discovery_data = fetch_accounts_data(start_date: nil, pending: true)
        discovered_count = discovery_data&.dig(:accounts)&.size.to_i
        Rails.logger.info "SimpleFin discovery (pending=1) returned #{discovered_count} accounts"
      end

      if discovery_data && discovered_count > 0
        simplefin_item.upsert_simplefin_snapshot!(discovery_data)
        # Treat total as max unique accounts seen this run, not accumulation
        stats["total_accounts"] = [ stats["total_accounts"].to_i, discovered_count ].max
        discovery_data[:accounts]&.each do |account_data|
          begin
            import_account(account_data)
          rescue => e
            stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
            cat = classify_error(e)
            begin
              register_error(message: e.message.to_s, category: cat, account_id: account_data[:id], name: account_data[:name])
            rescue
              # no-op if account_data is missing keys
            end
            Rails.logger.warn("SimpleFin discovery: Skipping account due to error: #{e.class} - #{e.message}")
          ensure
            persist_stats!
          end
        end
      end
    end

    # Fetches accounts (and optionally transactions/holdings) from SimpleFin.
    #
    # Params:
    # - start_date: Date or nil — when provided, provider may filter by date window
    # - end_date:   Date or nil — optional end of window
    # - pending:    Boolean or nil — when true, ask provider to include pending/new
    #
    # Returns a Hash payload with keys like :accounts, or nil when an error is
    # handled internally via `handle_errors`.
    def fetch_accounts_data(start_date:, end_date: nil, pending: nil)
      # Debug logging to track exactly what's being sent to SimpleFin API
      start_str = start_date.respond_to?(:strftime) ? start_date.strftime("%Y-%m-%d") : "none"
      end_str = end_date.respond_to?(:strftime) ? end_date.strftime("%Y-%m-%d") : "current"
      days_requested = if start_date && end_date
        (end_date.to_date - start_date.to_date).to_i
      else
        "unknown"
      end
      Rails.logger.info "SimplefinItem::Importer - API Request: #{start_str} to #{end_str} (#{days_requested} days)"

      begin
        # Track API request count for quota awareness
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
        accounts_data = simplefin_provider.get_accounts(
          simplefin_item.access_url,
          start_date: start_date,
          end_date: end_date,
          pending: pending
        )
        # Soft warning when approaching SimpleFin daily refresh guidance
        if stats["api_requests"].to_i >= 20
          stats["rate_limit_warning"] = true
        end
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
        if accounts_data[:accounts].to_a.any?
          # Partial failure: record errors for visibility but continue processing accounts
          record_errors(accounts_data[:errors])
        else
          # Global failure: no accounts were returned; treat as fatal
          handle_errors(accounts_data[:errors])
          return nil
        end
      end

      # Some servers return a top-level message/string rather than an errors array
      if accounts_data[:error].present?
        if accounts_data[:accounts].to_a.any?
          record_errors([ accounts_data[:error] ])
        else
          handle_errors([ accounts_data[:error] ])
          return nil
        end
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
      account_id = account_data[:id].to_s

      # Validate required account_id to prevent duplicate creation
      return if account_id.blank?

      simplefin_account = simplefin_item.simplefin_accounts.find_or_initialize_by(
        account_id: account_id
      )

      # Store transactions and holdings separately from account data to avoid overwriting
      transactions = account_data[:transactions]
      holdings = account_data[:holdings]

      # Update all attributes; only update transactions if present to avoid wiping prior data
      attrs = {
        name: account_data[:name],
        account_type: (account_data["type"].presence || account_data[:type].presence || "unknown"),
        currency: (account_data[:currency].presence || account_data["currency"].presence || simplefin_account.currency.presence || simplefin_account.current_account&.currency.presence || simplefin_item.family&.currency.presence || "USD"),
        current_balance: account_data[:balance],
        available_balance: account_data[:"available-balance"],
        balance_date: (account_data["balance-date"] || account_data[:"balance-date"]),
        raw_payload: account_data,
        org_data: account_data[:org]
      }

      # Merge transactions from chunked imports (accumulate historical data)
      if transactions.is_a?(Array) && transactions.any?
        existing_transactions = simplefin_account.raw_transactions_payload.to_a
        merged_transactions = (existing_transactions + transactions).uniq do |tx|
          tx = tx.with_indifferent_access
          tx[:id] || tx[:fitid] || [ tx[:posted], tx[:amount], tx[:description] ]
        end
        attrs[:raw_transactions_payload] = merged_transactions
      end

      # Track whether incoming holdings are new/changed so we can materialize and refresh balances
      holdings_changed = false
      if holdings.is_a?(Array) && holdings.any?
        prior = simplefin_account.raw_holdings_payload.to_a
        if prior != holdings
          attrs[:raw_holdings_payload] = holdings
          # Also mirror into raw_payload['holdings'] so downstream calculators can use it
          raw = simplefin_account.raw_payload.is_a?(Hash) ? simplefin_account.raw_payload.deep_dup : {}
          raw = raw.with_indifferent_access
          raw[:holdings] = holdings
          attrs[:raw_payload] = raw
          holdings_changed = true
        end
      end

      simplefin_account.assign_attributes(attrs)

      # Inactive detection/toggling (non-blocking)
      begin
        update_inactive_state(simplefin_account, account_data)
      rescue => e
        Rails.logger.warn("SimpleFin: inactive-state evaluation failed for sfa=#{simplefin_account.id || account_id}: #{e.class} - #{e.message}")
      end

      # Final validation before save to prevent duplicates
      if simplefin_account.account_id.blank?
        simplefin_account.account_id = account_id
      end

      begin
        simplefin_account.save!

        # Post-save side effects
        acct = simplefin_account.current_account
        if acct
          # Refresh credit attributes when available-balance present
          if acct.accountable_type == "CreditCard" && account_data[:"available-balance"].present?
            begin
              SimplefinAccount::Liabilities::CreditProcessor.new(simplefin_account).process
            rescue => e
              Rails.logger.warn("SimpleFin: credit post-import refresh failed for sfa=#{simplefin_account.id}: #{e.class} - #{e.message}")
            end
          end

          # If holdings changed for an investment/crypto account, enqueue holdings apply job and recompute cash balance
          if holdings_changed && [ "Investment", "Crypto" ].include?(acct.accountable_type)
            # Debounce per importer run per SFA
            unless @enqueued_holdings_job_ids.include?(simplefin_account.id)
              SimplefinHoldingsApplyJob.perform_later(simplefin_account.id)
              @enqueued_holdings_job_ids << simplefin_account.id
            end

            # Recompute cash balance using existing calculator; avoid altering canonical ledger balances
            begin
              calculator = SimplefinAccount::Investments::BalanceCalculator.new(simplefin_account)
              new_cash = calculator.cash_balance
              acct.update!(cash_balance: new_cash)
            rescue => e
              Rails.logger.warn("SimpleFin: cash balance recompute failed for sfa=#{simplefin_account.id}: #{e.class} - #{e.message}")
            end
          end
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Treat duplicates/validation failures as partial success: count and surface friendly error, then continue
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        msg = e.message.to_s
        if msg.downcase.include?("already been taken") || msg.downcase.include?("unique")
          msg = "Duplicate upstream account detected for SimpleFin (account_id=#{account_id}). Try relinking to an existing manual account."
        end
        register_error(message: msg, category: "other", account_id: account_id, name: account_data[:name])
        persist_stats!
        nil
      ensure
        # Ensure stats like zero_runs/inactive are persisted even when no errors occur,
        # particularly helpful for focused unit tests that call import_account directly.
        persist_stats!
      end
    end


    # Record non-fatal provider errors into sync stats without raising, so the
    # rest of the accounts can continue to import. This is used when the
    # response contains both :accounts and :errors.
    def record_errors(errors)
      arr = Array(errors)
      return if arr.empty?

      # Determine if these errors indicate the item needs an update (e.g. 2FA)
      needs_update = arr.any? do |error|
        if error.is_a?(String)
          down = error.downcase
          down.include?("reauth") || down.include?("auth") || down.include?("two-factor") || down.include?("2fa") || down.include?("forbidden") || down.include?("unauthorized")
        else
          code = error[:code].to_s.downcase
          type = error[:type].to_s.downcase
          code.include?("auth") || code.include?("token") || type.include?("auth")
        end
      end

      if needs_update
        Rails.logger.warn("SimpleFin: marking item ##{simplefin_item.id} requires_update due to auth-related provider errors")
        simplefin_item.update!(status: :requires_update)
        ActiveSupport::Notifications.instrument(
          "simplefin.item_requires_update",
          item_id: simplefin_item.id,
          reason: "provider_errors_partial",
          count: arr.size
        )
      end

      Rails.logger.info("SimpleFin: recording #{arr.size} non-fatal provider error(s) with partial data present")
      ActiveSupport::Notifications.instrument(
        "simplefin.provider_errors",
        item_id: simplefin_item.id,
        count: arr.size
      )

      arr.each do |error|
        msg = if error.is_a?(String)
          error
        else
          error[:description] || error[:message] || error[:error] || error.to_s
        end
        down = msg.to_s.downcase
        category = if down.include?("timeout") || down.include?("timed out")
          "network"
        elsif down.include?("auth") || down.include?("reauth") || down.include?("forbidden") || down.include?("unauthorized") || down.include?("2fa") || down.include?("two-factor")
          "auth"
        elsif down.include?("429") || down.include?("rate limit")
          "api"
        else
          "other"
        end
        register_error(message: msg, category: category)
      end
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
        Rails.logger.warn("SimpleFin: marking item ##{simplefin_item.id} requires_update due to fatal auth error(s): #{error_messages}")
        simplefin_item.update!(status: :requires_update)
      end

      down = error_messages.downcase
      # Detect and surface rate-limit specifically with a friendlier exception
      if down.include?("make fewer requests") ||
         down.include?("only refreshed once every 24 hours") ||
         down.include?("rate limit")
        Rails.logger.info("SimpleFin: raising RateLimitedError for item ##{simplefin_item.id}: #{error_messages}")
        ActiveSupport::Notifications.instrument(
          "simplefin.rate_limited",
          item_id: simplefin_item.id,
          message: error_messages
        )
        raise RateLimitedError, "SimpleFin rate limit: data refreshes at most once every 24 hours. Try again later."
      end

      # Fall back to generic SimpleFin error classified as :api_error
      Rails.logger.error("SimpleFin fatal API error for item ##{simplefin_item.id}: #{error_messages}")
      ActiveSupport::Notifications.instrument(
        "simplefin.fatal_error",
        item_id: simplefin_item.id,
        message: error_messages
      )
      raise Provider::Simplefin::SimplefinError.new(
        "SimpleFin API errors: #{error_messages}",
        :api_error
      )
    end

    # Classify exceptions into simple buckets for UI stats
    def classify_error(e)
      msg = e.message.to_s.downcase
      klass = e.class.name.to_s
      # Avoid referencing Net::OpenTimeout/ReadTimeout constants (may not be loaded)
      is_timeout = msg.include?("timeout") || msg.include?("timed out") || klass.include?("Timeout")
      case
      when is_timeout
        "network"
      when msg.include?("auth") || msg.include?("reauth") || msg.include?("forbidden") || msg.include?("unauthorized")
        "auth"
      when msg.include?("429") || msg.include?("too many requests") || msg.include?("rate limit") || msg.include?("5xx") || msg.include?("502") || msg.include?("503") || msg.include?("504")
        "api"
      else
        "other"
      end
    end

    def initial_sync_lookback_period
      # Default to 7 days for initial sync to avoid API limits
      7
    end

    def sync_buffer_period
      # Default to 7 days buffer for subsequent syncs
      7
    end
end
