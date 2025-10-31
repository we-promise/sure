class SimplefinAccount::Processor
  attr_reader :simplefin_account

  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  # Each step represents different SimpleFin data processing
  # Processing the account is the first step and if it fails, we halt
  # Each subsequent step can fail independently, but we continue processing
  def process
    # If account is missing (e.g., user deleted the connection and re-linked later),
    # try to auto-reconnect to an existing manual account with the same normalized name.
    unless simplefin_account.current_account.present?
      auto_relink_existing_manual_account
    end

    unless simplefin_account.current_account.present?
      return
    end

    process_account!
    # Ensure provider link exists after processing the account/balance
    begin
      simplefin_account.ensure_account_provider!
    rescue => e
      Rails.logger.warn("SimpleFin provider link ensure failed for #{simplefin_account.id}: #{e.class} - #{e.message}")
    end
    process_transactions
    process_investments
    process_liabilities
  end

  private

    # Attempt to auto-relink this SimpleFin upstream account to an existing manual Account
    # that has the same normalized name. This helps avoid duplicates under "Other accounts"
    # when users delete/re-link a SimpleFin connection.
    def auto_relink_existing_manual_account
      name = simplefin_account.name.to_s
      return if name.blank?
      family = simplefin_account.simplefin_item.family
      norm = ->(s) { s.to_s.downcase.gsub(/\s+/, " ").strip }

      manuals = family.accounts
        .left_joins(:account_providers)
        .where(account_providers: { id: nil }) # only manual accounts
        .to_a

      # Heuristics: last4 (if available) > balance within $0.01 > normalized name
      sfa_balance = (simplefin_account.current_balance || simplefin_account.available_balance).to_d rescue 0.to_d

      # Extract last4 from raw payload if present
      raw = (simplefin_account.raw_payload || {}).with_indifferent_access
      sfa_last4 = raw[:mask] || raw[:last4] || raw[:"last-4"] || raw[:"account_number_last4"]
      sfa_last4 = sfa_last4.to_s.strip.presence

      # Try last4 first if manuals expose similar info
      candidate = manuals.find do |a|
        a_last4 = nil
        %i[mask last4 number_last4 account_number_last4].each do |k|
          if a.respond_to?(k)
            val = a.public_send(k)
            a_last4 = val.to_s.strip.presence if val.present?
            break if a_last4
          end
        end
        a_last4.present? && sfa_last4.present? && a_last4 == sfa_last4
      end

      # Next: balance tolerance
      if candidate.nil? && sfa_balance.nonzero?
        candidate = manuals.find do |a|
          begin
            ab = (a.balance || a.cash_balance || 0).to_d
            (ab - sfa_balance).abs <= BigDecimal("0.01")
          rescue
            false
          end
        end
      end

      # Finally: normalized name
      if candidate.nil?
        candidate = manuals.find { |a| norm.call(a.name) == norm.call(name) }
      end

      if candidate
        # Link the manual account to this upstream
        candidate.update!(simplefin_account_id: simplefin_account.id)
        AccountProvider.find_or_create_by!(
          account: candidate,
          provider_type: "SimplefinAccount",
          provider_id: simplefin_account.id
        )
        simplefin_account.reload
      end
    rescue => e
      Rails.logger.warn("SimpleFin auto-relink failed for #{simplefin_account.id}: #{e.class} - #{e.message}")
    end

    def process_account!
      # This should not happen in normal flow since accounts are created manually
      # during setup, but keeping as safety check
      if simplefin_account.current_account.blank?
        Rails.logger.error("SimpleFin account #{simplefin_account.id} has no associated Account - this should not happen after manual setup")
        return
      end

      # Update account balance and cash balance from latest SimpleFin data
      account = simplefin_account.current_account
      balance = simplefin_account.current_balance || simplefin_account.available_balance || 0

      # SimpleFin returns negative balances for credit cards (liabilities)
      # But Maybe expects positive balances for liabilities
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = balance.abs
      end

      # Calculate cash balance correctly for investment accounts
      cash_balance = if account.accountable_type == "Investment"
        calculator = SimplefinAccount::Investments::BalanceCalculator.new(simplefin_account)
        calculator.cash_balance
      else
        balance
      end

      account.update!(
        balance: balance,
        cash_balance: cash_balance,
        currency: simplefin_account.currency
      )
    end

    def process_transactions
      SimplefinAccount::Transactions::Processor.new(simplefin_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def process_investments
      return unless simplefin_account.current_account&.accountable_type == "Investment"
      SimplefinAccount::Investments::TransactionsProcessor.new(simplefin_account).process
      SimplefinAccount::Investments::HoldingsProcessor.new(simplefin_account).process
    rescue => e
      report_exception(e, "investments")
    end

    def process_liabilities
      case simplefin_account.current_account&.accountable_type
      when "CreditCard"
        SimplefinAccount::Liabilities::CreditProcessor.new(simplefin_account).process
      when "Loan"
        SimplefinAccount::Liabilities::LoanProcessor.new(simplefin_account).process
      end
    rescue => e
      report_exception(e, "liabilities")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          simplefin_account_id: simplefin_account.id,
          context: context
        )
      end
    end
end
