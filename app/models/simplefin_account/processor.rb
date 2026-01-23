class SimplefinAccount::Processor
  include SimplefinNumericHelpers
  attr_reader :simplefin_account, :skipped_entries

  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
    @skipped_entries = []
  end

  # Each step represents different SimpleFin data processing
  # Processing the account is the first step and if it fails, we halt
  # Each subsequent step can fail independently, but we continue processing
  def process
    # If the account is missing (e.g., user deleted the connection and re‑linked later),
    # do not auto‑link. Relinking is now a manual, user‑confirmed flow via the Relink modal.
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

    def process_account!
      # This should not happen in normal flow since accounts are created manually
      # during setup, but keeping as safety check
      if simplefin_account.current_account.blank?
        Rails.logger.error("SimpleFin account #{simplefin_account.id} has no associated Account - this should not happen after manual setup")
        return
      end

      # Update account balance and cash balance from latest SimpleFin data
      account = simplefin_account.current_account

      # Extract raw values from SimpleFIN snapshot
      bal   = to_decimal(simplefin_account.current_balance)
      avail = to_decimal(simplefin_account.available_balance)

      # Choose an observed value prioritizing posted balance first
      # Use available_balance only when current_balance is truly missing (nil),
      # not when it's explicitly zero (e.g., dormant credit card with no debt)
      observed = simplefin_account.current_balance.nil? ? avail : bal

      # Determine if this should be treated as a liability for normalization
      is_linked_liability = [ "CreditCard", "Loan" ].include?(account.accountable_type)
      raw = (simplefin_account.raw_payload || {}).with_indifferent_access
      org = (simplefin_account.org_data || {}).with_indifferent_access
      inferred = Simplefin::AccountTypeMapper.infer(
        name: simplefin_account.name,
        holdings: raw[:holdings],
        extra: simplefin_account.extra,
        balance: bal,
        available_balance: avail,
        institution: org[:name]
      ) rescue nil
      is_mapper_liability = inferred && [ "CreditCard", "Loan" ].include?(inferred.accountable_type)
      is_liability = is_linked_liability || is_mapper_liability

      if is_mapper_liability && !is_linked_liability
        Rails.logger.warn(
          "SimpleFIN liability normalization: linked account #{account.id} type=#{account.accountable_type} " \
          "appears to be liability via mapper (#{inferred.accountable_type}). Normalizing as liability; consider relinking."
        )
      end

      balance = observed
      if is_liability
        # 1) Try transaction-history heuristic when enabled
        begin
          result = SimplefinAccount::Liabilities::OverpaymentAnalyzer
            .new(simplefin_account, observed_balance: observed)
            .call

          case result.classification
          when :credit
            balance = -observed.abs
            Rails.logger.info(
              "SimpleFIN overpayment heuristic: classified as credit for sfa=#{simplefin_account.id}, " \
              "observed=#{observed.to_s('F')} metrics=#{result.metrics.slice(:charges_total, :payments_total, :tx_count).inspect}"
            )
            Sentry.add_breadcrumb(Sentry::Breadcrumb.new(
              category: "simplefin",
              message: "liability_sign=credit",
              data: { sfa_id: simplefin_account.id, observed: observed.to_s("F") }
            )) rescue nil
          when :debt
            balance = observed.abs
            Rails.logger.info(
              "SimpleFIN overpayment heuristic: classified as debt for sfa=#{simplefin_account.id}, " \
              "observed=#{observed.to_s('F')} metrics=#{result.metrics.slice(:charges_total, :payments_total, :tx_count).inspect}"
            )
            Sentry.add_breadcrumb(Sentry::Breadcrumb.new(
              category: "simplefin",
              message: "liability_sign=debt",
              data: { sfa_id: simplefin_account.id, observed: observed.to_s("F") }
            )) rescue nil
          else
            # 2) Fall back to existing sign-only logic (log unknown for observability)
            begin
              obs = {
                reason: result.reason,
                tx_count: result.metrics[:tx_count],
                charges_total: result.metrics[:charges_total],
                payments_total: result.metrics[:payments_total],
                observed: observed.to_s("F")
              }.compact
              Rails.logger.info("SimpleFIN overpayment heuristic: unknown; falling back #{obs.inspect}")
            rescue
              # no-op
            end
            balance = normalize_liability_balance(observed, bal, avail)
          end
        rescue NameError
          # Analyzer not loaded; keep legacy behavior
          balance = normalize_liability_balance(observed, bal, avail)
        rescue => e
          Rails.logger.warn("SimpleFIN overpayment heuristic error for sfa=#{simplefin_account.id}: #{e.class} - #{e.message}")
          balance = normalize_liability_balance(observed, bal, avail)
        end
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
      processor = SimplefinAccount::Transactions::Processor.new(simplefin_account)
      processor.process
      @skipped_entries.concat(processor.skipped_entries)
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

    # Helpers
    # to_decimal and same_sign? provided by SimplefinNumericHelpers concern

    def normalize_liability_balance(observed, bal, avail)
      both_present = bal.nonzero? && avail.nonzero?
      if both_present && same_sign?(bal, avail)
        if bal.positive? && avail.positive?
          return -observed.abs
        elsif bal.negative? && avail.negative?
          return observed.abs
        end
      end
      -observed
    end
end
