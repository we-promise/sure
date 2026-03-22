# frozen_string_literal: true

class IndexaCapitalAccount::Processor
  include IndexaCapitalAccount::DataHelpers

  attr_reader :indexa_capital_account

  def initialize(indexa_capital_account)
    @indexa_capital_account = indexa_capital_account
  end

  def process
    account = indexa_capital_account.current_account
    return unless account

    Rails.logger.info "IndexaCapitalAccount::Processor - Processing account #{indexa_capital_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Process holdings
    holdings_count = indexa_capital_account.raw_holdings_payload&.size || 0
    Rails.logger.info "IndexaCapitalAccount::Processor - Holdings payload has #{holdings_count} items"

    if indexa_capital_account.raw_holdings_payload.present?
      Rails.logger.info "IndexaCapitalAccount::Processor - Processing holdings..."
      IndexaCapitalAccount::HoldingsProcessor.new(indexa_capital_account).process
    else
      Rails.logger.warn "IndexaCapitalAccount::Processor - No holdings payload to process"
    end

    # Process activities (trades, dividends, etc.)
    activities_count = indexa_capital_account.raw_activities_payload&.size || 0
    Rails.logger.info "IndexaCapitalAccount::Processor - Activities payload has #{activities_count} items"

    if indexa_capital_account.raw_activities_payload.present?
      Rails.logger.info "IndexaCapitalAccount::Processor - Processing activities..."
      IndexaCapitalAccount::ActivitiesProcessor.new(indexa_capital_account).process
    else
      Rails.logger.warn "IndexaCapitalAccount::Processor - No activities payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "IndexaCapitalAccount::Processor - Broadcast sync complete for account #{account.id}"

    { holdings_processed: holdings_count > 0, activities_processed: activities_count > 0 }
  end

  private

    def update_account_balance(account)
      # Calculate total balance and cash balance from provider data
      total_balance = calculate_total_balance
      cash_balance = calculate_cash_balance

      Rails.logger.info "IndexaCapitalAccount::Processor - Balance update: total=#{total_balance}, cash=#{cash_balance}"

      # Update the cached fields on the account
      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: indexa_capital_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(total_balance)
    end

    def calculate_total_balance
      # Calculate total from holdings + cash for accuracy
      holdings_value = calculate_holdings_value
      cash_value = indexa_capital_account.cash_balance || 0

      calculated_total = holdings_value + cash_value

      # Use calculated total if we have holdings, otherwise trust API value
      if holdings_value > 0
        Rails.logger.info "IndexaCapitalAccount::Processor - Using calculated total: holdings=#{holdings_value} + cash=#{cash_value} = #{calculated_total}"
        calculated_total
      elsif indexa_capital_account.current_balance.present?
        Rails.logger.info "IndexaCapitalAccount::Processor - Using API total: #{indexa_capital_account.current_balance}"
        indexa_capital_account.current_balance
      else
        calculated_total
      end
    end

    def calculate_cash_balance
      # Use provider's cash_balance directly
      # Note: Can be negative for margin accounts
      cash = indexa_capital_account.cash_balance
      Rails.logger.info "IndexaCapitalAccount::Processor - Cash balance from API: #{cash.inspect}"
      cash || BigDecimal("0")
    end

    def calculate_holdings_value
      holdings_data = indexa_capital_account.raw_holdings_payload || []
      return 0 if holdings_data.empty?

      holdings_data.sum do |holding|
        data = holding.is_a?(Hash) ? holding.with_indifferent_access : {}
        # Indexa Capital: amount = total market value, or titles * price
        amount = parse_decimal(data[:amount])
        if amount
          amount
        else
          titles = parse_decimal(data[:titles] || data[:quantity] || data[:units]) || 0
          price = parse_decimal(data[:price]) || 0
          titles * price
        end
      end
    end
end
