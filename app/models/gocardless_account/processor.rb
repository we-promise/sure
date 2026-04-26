class GocardlessAccount::Processor
  class ProcessingError < StandardError; end

  attr_reader :gocardless_account

  def initialize(gocardless_account)
    @gocardless_account = gocardless_account
  end

  def process
    unless gocardless_account.current_account.present?
      Rails.logger.info "GocardlessAccount::Processor - No linked account for gocardless_account #{gocardless_account.id}, skipping"
      return
    end

    Rails.logger.info "GocardlessAccount::Processor - Processing gocardless_account #{gocardless_account.id}"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "GocardlessAccount::Processor - Failed to process account #{gocardless_account.id}: #{e.message}"
      raise
    end

    account = gocardless_account.current_account
    is_first_sync = !account.entries.where(source: "gocardless").exists?

    process_transactions

    if is_first_sync && gocardless_account.current_balance.present? && account.asset?
      recalculate_opening_anchor(account)
    end
  end

  private

    def process_account!
      account  = gocardless_account.current_account
      balance  = gocardless_account.current_balance
      currency = gocardless_account.currency.presence || account.currency || "GBP"

      # Skip balance update if no balance has been fetched from the API yet.
      # A nil current_balance means the GoCardless endpoint was unavailable (e.g. Monzo
      # delays balance availability after auth). Calling set_current_balance(0) would
      # create an incorrect anchor valuation and overwrite any previously correct balance.
      if balance.nil?
        Rails.logger.info "GocardlessAccount::Processor - current_balance not yet available for gocardless_account #{gocardless_account.id}; skipping balance anchor update"
        account.update!(currency: currency) if account.currency != currency
        return
      end

      # For liability accounts, balance is stored as a positive debt amount.
      balance = balance.abs if account.accountable_type == "Loan"

      ActiveRecord::Base.transaction do
        account.update!(currency: currency)

        # set_current_balance creates a current_anchor valuation entry, enabling
        # Balance::ReverseCalculator to derive historical balances correctly.
        result = account.set_current_balance(balance)
        raise ProcessingError, "Failed to set current balance: #{result.error}" unless result.success?
      end
    end

    def process_transactions
      GocardlessAccount::Transactions::Processor.new(gocardless_account).process
    end

    def recalculate_opening_anchor(account)
      # ReverseCalculator formula: balance_at_t = balance_later + Σ(entries between t and later)
      # For asset accounts, positive amounts = outflows (reduce balance), negative = inflows.
      # So: opening_balance = current_balance + tx_sum gives the pre-transaction starting balance.
      tx_sum = account.entries.where(source: "gocardless").sum(:amount)
      opening_balance = gocardless_account.current_balance + tx_sum

      result = Account::OpeningBalanceManager.new(account).set_opening_balance(balance: opening_balance)

      if result.success?
        Rails.logger.info "GocardlessAccount::Processor - Opening anchor set to #{opening_balance} (current_balance=#{gocardless_account.current_balance}, tx_sum=#{tx_sum})"
      else
        Rails.logger.warn "GocardlessAccount::Processor - Could not set opening anchor: #{result.error}"
      end
    end
end
