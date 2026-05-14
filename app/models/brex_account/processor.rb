# frozen_string_literal: true

class BrexAccount::Processor
  include CurrencyNormalizable

  attr_reader :brex_account

  def initialize(brex_account)
    @brex_account = brex_account
  end

  def process
    unless brex_account.current_account.present?
      Rails.logger.info "BrexAccount::Processor - No linked account for brex_account #{brex_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "BrexAccount::Processor - Failed to process account #{brex_account.id}: #{e.message}"
    report_exception(e, "account")
    raise
  end

  private

    def process_account!
      account = brex_account.current_account
      balance = brex_account.current_balance
      currency = parse_currency(brex_account.currency)

      if balance.nil?
        Rails.logger.warn "BrexAccount::Processor - current_balance is nil for brex_account #{brex_account.id}, defaulting to 0"
        balance = 0
      end

      if currency.nil?
        Rails.logger.warn "BrexAccount::Processor - currency parse failed for brex_account #{brex_account.id}: #{brex_account.currency.inspect}, defaulting to USD"
        Sentry.capture_message("BrexAccount currency parse failed", level: :warning) do |scope|
          scope.set_tags(brex_account_id: brex_account.id)
          scope.set_context("brex_account", {
            id: brex_account.id,
            currency: brex_account.currency
          })
        end
        currency = "USD"
      end

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )

      if account.accountable_type == "CreditCard" && brex_account.available_balance.present?
        account.accountable.update!(available_credit: brex_account.available_balance)
      end
    end

    # Transaction import errors are logged and swallowed so balance sync can continue.
    def process_transactions
      BrexAccount::Transactions::Processor.new(brex_account).process
    rescue StandardError => e
      Rails.logger.error "BrexAccount::Processor - Failed to process transactions for brex_account #{brex_account.id}: #{e.message}"
      Rails.logger.error Array(e.backtrace).first(10).join("\n")
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          brex_account_id: brex_account.id,
          context: context
        )
      end
    end
end
