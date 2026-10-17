# frozen_string_literal: true

class WiseAccount::Processor
  attr_reader :wise_account, :import_complete

  # import_complete: see WiseItem#process_accounts. Processing an account on
  # its own leaves it false, so nothing is deleted or rewritten.
  def initialize(wise_account, import_complete: false)
    @wise_account = wise_account
    @import_complete = import_complete
  end

  def process
    unless wise_account.current_account.present?
      Rails.logger.info "WiseAccount::Processor - No linked account for wise_account #{wise_account.id}, skipping"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "WiseAccount::Processor - Failed to process account #{wise_account.id}: #{e.message}"
    Sentry.capture_exception(e) { |s| s.set_tags(wise_account_id: wise_account.id) }
    raise
  end

  private

    def process_account!
      account = wise_account.current_account
      balance = wise_account.current_balance || 0

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: wise_account.currency
      )
    end

    def process_transactions
      WiseAccount::Transactions::Processor.new(wise_account, import_complete: import_complete).process
    rescue StandardError => e
      Rails.logger.error "WiseAccount::Processor - Failed to process transactions for wise_account #{wise_account.id}: #{e.message}"
      Rails.logger.error Array(e.backtrace).first(10).join("\n")
      Sentry.capture_exception(e) { |s| s.set_tags(wise_account_id: wise_account.id) }
    end
end
