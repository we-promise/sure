# Processes a SophtronAccount to update Maybe Account and Transaction records.
#
# This processor is responsible for:
# 1. Updating the linked Maybe Account's balance from Sophtron data
# 2. Processing stored transactions to create Maybe Transaction records
#
# The processor handles currency normalization and sign conventions for
# different account types (e.g., credit cards use inverted signs).
class SophtronAccount::Processor
  include CurrencyNormalizable

  attr_reader :sophtron_account

  # Initializes a new processor for a Sophtron account.
  #
  # @param sophtron_account [SophtronAccount] The account to process
  def initialize(sophtron_account)
    @sophtron_account = sophtron_account
  end

  # Processes the account to update balances and transactions.
  #
  # This method:
  # - Validates that the account is linked to a Maybe Account
  # - Updates the Maybe Account's balance from Sophtron data
  # - Processes all stored transactions to create Transaction records
  #
  # @return [Hash, nil] Transaction processing result hash or nil if no linked account
  # @raise [StandardError] if processing fails (errors are logged and reported to Sentry)
  def process
    unless sophtron_account.current_account.present?
      Rails.logger.info "SophtronAccount::Processor - No linked account for sophtron_account #{sophtron_account.id}, skipping processing"
      return
    end

    Rails.logger.info "SophtronAccount::Processor - Processing sophtron_account #{sophtron_account.id} (account #{sophtron_account.account_id})"
    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "SophtronAccount::Processor - Failed to process account #{sophtron_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
  end

  private

    # Updates the linked Maybe Account's balance from Sophtron data.
    #
    # Handles sign conventions for different account types:
    # - CreditCard and Loan accounts use inverted signs (negated)
    # - Other account types use Sophtron's native sign convention
    #
    # @return [void]
    # @raise [ActiveRecord::RecordInvalid] if the account update fails
    def process_account!
      if sophtron_account.current_account.blank?
        Rails.logger.error("Sophtron account #{sophtron_account.id} has no associated Account")
        return
      end

      # Update account balance from latest Sophtron data
      account = sophtron_account.current_account
      balance = sophtron_account.balance || sophtron_account.available_balance || 0

      # Sophtron balance convention matches our app convention:
      # - Positive balance = debt (you owe money)
      # - Negative balance = credit balance (bank owes you, e.g., overpayment)
      # No sign conversion needed - pass through as-is (same as Plaid)
      #
      # Exception: CreditCard and Loan accounts return inverted signs
      # Provider returns negative for positive balance, so we negate it
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = -balance
      end

      # Normalize currency with fallback chain: parsed sophtron currency -> existing account currency -> USD
      currency = parse_currency(sophtron_account.currency) || account.currency || "USD"
      # Update account balance
      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    # Processes all stored transactions for this account.
    #
    # Delegates to SophtronAccount::Transactions::Processor to convert
    # raw transaction data into Maybe Transaction records.
    #
    # @return [void]
    # @raise [StandardError] if transaction processing fails
    def process_transactions
      SophtronAccount::Transactions::Processor.new(sophtron_account).process
    rescue StandardError => e
      Rails.logger.error "SophtronAccount::Processor - Failed to process transactions for sophtron_account #{sophtron_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "transactions")
      raise
    end

    # Reports an exception to Sentry with Sophtron account context.
    #
    # @param error [Exception] The error to report
    # @param context [String] Additional context (e.g., 'account', 'transactions')
    # @return [void]
    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          sophtron_account_id: sophtron_account.id,
          context: context
        )
      end
    end
end
