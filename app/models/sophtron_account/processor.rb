# Processes a SophtronAccount to update Maybe Account and Transaction records.
#
# This processor is responsible for:
# 1. Updating the linked Maybe Account's balance from Sophtron data
# 2. Processing stored transactions to create Maybe Transaction records
#
# The processor handles currency normalization and sign conventions for
# different account types. Credit cards can override the historical sign flip.
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
      account, balance, currency = balance_for_anchor
    rescue StandardError => e
      Rails.logger.error "SophtronAccount::Processor - Failed to process account #{sophtron_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    return unless process_transactions

    begin
      anchor_account!(account, balance, currency)
    rescue StandardError => e
      Rails.logger.error "SophtronAccount::Processor - Failed to anchor account #{sophtron_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end
  end

  # Applies the provider balance immediately. Used when the user changes the
  # balance sign override; the sync path imports transactions before anchoring.
  def process_account!
    account, balance, currency = balance_for_anchor
    return if account.nil?

    anchor_account!(account, balance, currency)
  end

  private

    # Computes the linked Maybe Account's balance from Sophtron data.
    #
    # Handles sign conventions for different account types:
    # - Credit cards negate the provider balance unless a balance sign
    #   override says the amount is debt or a genuine credit
    # - Loans always use inverted signs (negated)
    # - Other account types use Sophtron's native sign convention
    #
    # @return [Array(Account, Numeric, String), nil] account, balance and currency
    # @raise [StandardError] if the account cannot be read
    def balance_for_anchor
      account = sophtron_account.current_account
      if account.blank?
        Rails.logger.error("Sophtron account #{sophtron_account.id} has no associated Account")
        return
      end

      balance = signed_balance(account, sophtron_account.observed_balance)

      # Normalize currency with fallback chain: parsed sophtron currency -> existing account currency -> USD
      currency = parse_currency(sophtron_account.currency) || account.currency || "USD"

      [ account, balance, currency ]
    end

    # Writes the anchor only after the transaction batch has been imported, so the
    # manager can judge the standing anchor against a complete ledger.
    def anchor_account!(account, balance, currency)
      # The anchor is what a later account sync reads. Write it here, without
      # queueing that sync, so the caller can schedule one sync after every
      # account has been updated.
      ActiveRecord::Base.transaction do
        account.update!(currency: currency)
        result = account.set_current_balance(balance, schedule_sync: false)
        raise StandardError, "Failed to set current balance: #{result.error}" unless result.success?
        account.update!(cash_balance: balance) unless result.historical?
      end
    end

    # Processes all stored transactions for this account.
    #
    # Delegates to SophtronAccount::Transactions::Processor to convert
    # raw transaction data into Maybe Transaction records.
    #
    # @return [Boolean] true when the batch imported without per-row failures
    def process_transactions
      result = SophtronAccount::Transactions::Processor.new(sophtron_account).process
      result[:success]
    rescue StandardError => e
      Rails.logger.error "SophtronAccount::Processor - Failed to process transactions for sophtron_account #{sophtron_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "transactions")
      false
    end

    # Converts a Sophtron balance into Sure's stored sign.
    #
    # Sure stores liability debt as a positive amount. Automatic mode keeps
    # the historical flip for credit cards and loans. An explicit credit card
    # override is authoritative because some Sophtron institutions already
    # report debt as positive and others report it as negative.
    #
    # @param account [Account] The linked Maybe account
    # @param observed [Numeric] The provider balance
    # @return [Numeric] The balance to store
    def signed_balance(account, observed)
      if account.accountable_type == "CreditCard"
        case sophtron_account.balance_sign_override
        when "credit"
          -observed.abs
        when "debt"
          observed.abs
        else
          -observed
        end
      elsif account.accountable_type == "Loan"
        -observed
      else
        observed
      end
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
