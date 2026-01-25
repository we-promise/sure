class SnaptradeAccount::Processor
  include SnaptradeAccount::DataHelpers

  attr_reader :snaptrade_account

  def initialize(snaptrade_account)
    @snaptrade_account = snaptrade_account
  end

  def process
    account = snaptrade_account.current_account
    return unless account

    Rails.logger.info "SnaptradeAccount::Processor - Processing account #{snaptrade_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing holdings/activities)
    # This creates the current_anchor valuation needed for reverse sync
    update_account_balance(account)

    # Process holdings
    holdings_count = snaptrade_account.raw_holdings_payload&.size || 0
    Rails.logger.info "SnaptradeAccount::Processor - Holdings payload has #{holdings_count} items"

    if snaptrade_account.raw_holdings_payload.present?
      Rails.logger.info "SnaptradeAccount::Processor - Processing holdings..."
      SnaptradeAccount::HoldingsProcessor.new(snaptrade_account).process
    else
      Rails.logger.warn "SnaptradeAccount::Processor - No holdings payload to process"
    end

    # Process activities (trades, dividends, etc.)
    activities_count = snaptrade_account.raw_activities_payload&.size || 0
    Rails.logger.info "SnaptradeAccount::Processor - Activities payload has #{activities_count} items"

    if snaptrade_account.raw_activities_payload.present?
      Rails.logger.info "SnaptradeAccount::Processor - Processing activities..."
      SnaptradeAccount::ActivitiesProcessor.new(snaptrade_account).process
    else
      Rails.logger.warn "SnaptradeAccount::Processor - No activities payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    # This is critical for fresh account links where the sync complete broadcast
    # might be delayed by child syncs (balance calculations)
    account.broadcast_sync_complete
    Rails.logger.info "SnaptradeAccount::Processor - Broadcast sync complete for account #{account.id}"

    { holdings_processed: holdings_count > 0, activities_processed: activities_count > 0 }
  end

  private

    def update_account_balance(account)
      # Calculate total balance and cash balance from SnapTrade data
      total_balance = calculate_total_balance
      cash_balance = calculate_cash_balance

      Rails.logger.info "SnaptradeAccount::Processor - Balance update: total=#{total_balance}, cash=#{cash_balance}"

      # Update the cached fields on the account
      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: snaptrade_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(total_balance)
    end

    def calculate_total_balance
      # Calculate total from holdings + cash for accuracy
      # SnapTrade's current_balance can sometimes be stale or just the cash value
      holdings_value = calculate_holdings_value
      cash_value = snaptrade_account.cash_balance || 0

      calculated_total = holdings_value + cash_value

      # Use calculated total if we have holdings, otherwise trust API value
      if holdings_value > 0
        Rails.logger.info "SnaptradeAccount::Processor - Using calculated total: holdings=#{holdings_value} + cash=#{cash_value} = #{calculated_total}"
        calculated_total
      elsif snaptrade_account.current_balance.present?
        Rails.logger.info "SnaptradeAccount::Processor - Using API total: #{snaptrade_account.current_balance}"
        snaptrade_account.current_balance
      else
        calculated_total
      end
    end

    def calculate_cash_balance
      # Use SnapTrade's cash_balance directly
      # Note: Can be negative for margin accounts
      cash = snaptrade_account.cash_balance
      Rails.logger.info "SnaptradeAccount::Processor - Cash balance from API: #{cash.inspect}"
      cash || BigDecimal("0")
    end

    def calculate_holdings_value
      holdings_data = snaptrade_account.raw_holdings_payload || []
      return 0 if holdings_data.empty?

      holdings_data.sum do |holding|
        data = holding.is_a?(Hash) ? holding.with_indifferent_access : {}
        units = parse_decimal(data[:units]) || 0
        price = parse_decimal(data[:price]) || 0
        units * price
      end
    end
end
