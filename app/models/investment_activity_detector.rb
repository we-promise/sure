# Detects internal investment activity (fund swaps, reinvestments) by comparing
# holdings snapshots between syncs and marks matching transactions as excluded
# from cashflow. This is provider-agnostic and works with any holdings data.
#
# Usage:
#   detector = InvestmentActivityDetector.new(account)
#   detector.detect_and_mark_internal_activity(current_holdings, recent_transactions)
#
class InvestmentActivityDetector
  def initialize(account)
    @account = account
  end

  # Class method for inferring activity label from description and amount
  # without needing a full detector instance
  # @param name [String] Transaction name/description
  # @param amount [Numeric] Transaction amount
  # @param account [Account, nil] Optional account for context (e.g., retirement plan detection)
  # @return [String, nil] Activity label or nil if unknown
  def self.infer_label_from_description(name, amount, account = nil)
    new(nil).send(:infer_from_description, name, amount, account)
  end

  # Call this after syncing transactions for an investment/crypto account
  # @param current_holdings [Array] Array of holding objects/hashes from provider
  # @param recent_transactions [Array<Transaction>] Recently imported transactions
  def detect_and_mark_internal_activity(current_holdings, recent_transactions)
    return unless @account.investment? || @account.crypto?
    return if current_holdings.blank?

    previous_snapshot = @account.holdings_snapshot_data || []

    # Find holdings changes that indicate buys/sells
    changes = detect_holdings_changes(previous_snapshot, current_holdings)

    # Match changes to transactions and mark them as excluded
    changes.each do |change|
      matched_entry = find_matching_entry(change, recent_transactions)
      next unless matched_entry

      transaction = matched_entry.entryable

      # Only auto-set if not already manually set by user (respect user overrides)
      unless matched_entry.locked?(:exclude_from_cashflow)
        matched_entry.update!(exclude_from_cashflow: true)
        matched_entry.lock_attr!(:exclude_from_cashflow)

        Rails.logger.info(
          "InvestmentActivityDetector: Auto-excluded entry #{matched_entry.id} " \
          "(#{matched_entry.name}) as internal #{change[:type]} of #{change[:symbol] || change[:description]}"
        )
      end

      # Set activity label if not already set
      if transaction.is_a?(Transaction) && transaction.investment_activity_label.blank?
        label = infer_activity_label(matched_entry, change[:type])
        transaction.update!(investment_activity_label: label) if label.present?
      end
    end

    # Store current snapshot for next comparison
    save_holdings_snapshot(current_holdings)
  end

  private

    # Infer activity label from change type and transaction description
    def infer_activity_label(entry, change_type)
      # If we know it's a buy or sell from holdings comparison
      return "Buy" if change_type == :buy
      return "Sell" if change_type == :sell

      # Otherwise try to infer from description
      infer_from_description(entry)
    end

    # Infer activity label from transaction description
    # Can be called with an Entry or with name/amount directly
    # @param entry_or_name [Entry, String] Entry object or transaction name
    # @param amount [Numeric, nil] Transaction amount (required if entry_or_name is String)
    # @param account [Account, nil] Optional account for context (e.g., retirement plan detection)
    def infer_from_description(entry_or_name, amount = nil, account = nil)
      if entry_or_name.respond_to?(:name)
        description = (entry_or_name.name || "").upcase
        amount = entry_or_name.amount || 0
        account ||= entry_or_name.try(:account)
      else
        description = (entry_or_name || "").upcase
        amount ||= 0
      end

      # Check if this is a retirement plan account (401k, 403b, etc.)
      account_name = (account&.name || "").upcase
      retirement_indicators = %w[401K 403B RETIREMENT TOTALSOURCE NETBENEFITS]
      retirement_phrases = [ "SAVINGS PLAN", "THRIFT PLAN", "PENSION" ]
      is_retirement_plan = retirement_indicators.any? { |ind| account_name.include?(ind) } ||
                           retirement_phrases.any? { |phrase| account_name.include?(phrase) }

      # Check for sweep/money market patterns (but NOT money market FUND purchases)
      # INVESTOR CL indicates this is a money market fund, not a sweep
      sweep_patterns = %w[SWEEP SETTLEMENT]
      money_market_sweep = description.include?("MONEY MARKET") && !description.include?("INVESTOR")
      common_money_market_tickers = %w[VMFXX SPAXX FDRXX SWVXX SPRXX]

      if sweep_patterns.any? { |p| description.include?(p) } ||
         money_market_sweep ||
         common_money_market_tickers.any? { |t| description == t }
        return amount.positive? ? "Sweep Out" : "Sweep In"
      end

      # Check for likely interest/dividend on money market funds
      # Small amounts (under $5) on money market funds are typically interest income
      money_market_fund_patterns = %w[MONEY\ MARKET VMFXX SPAXX FDRXX SWVXX SPRXX VUSXX]
      is_money_market_fund = money_market_fund_patterns.any? { |p| description.include?(p) }

      if is_money_market_fund && amount.abs < 5
        # Small money market amounts are interest, not buys/sells
        return "Interest"
      end

      # Check for dividend patterns
      if description == "CASH" || description.include?("DIVIDEND") ||
         description.include?("DISTRIBUTION")
        return "Dividend"
      end

      # Check for interest
      return "Interest" if description.include?("INTEREST")

      # Check for fees
      return "Fee" if description.include?("FEE") || description.include?("CHARGE")

      # Check for reinvestment
      return "Reinvestment" if description.include?("REINVEST")

      # Check for exchange/conversion
      return "Exchange" if description.include?("EXCHANGE") || description.include?("CONVERSION")

      # Check for contribution patterns
      return "Contribution" if description.include?("CONTRIBUTION") || description.include?("DEPOSIT")

      # Check for withdrawal patterns
      return "Withdrawal" if description.include?("WITHDRAWAL") || description.include?("DISBURSEMENT")

      # Check for fund names that indicate buy/sell activity
      # Positive amount = money out from account perspective = buying securities
      # Negative amount = money in = selling securities
      fund_patterns = %w[
        INDEX FUND ADMIRAL ETF SHARES TRUST
        VANGUARD FIDELITY SCHWAB ISHARES SPDR
        500\ INDEX TOTAL\ MARKET GROWTH BOND
      ]

      # Common fund ticker patterns
      fund_ticker_patterns = %w[
        VFIAX VTSAX VXUS VBTLX VTIAX VTTVX
        VTI VOO VGT VIG VYM VGIT
        FXAIX FZROX FSKAX FBALX
        SWTSX SWPPX SCHD SCHX
        SPY QQQ IVV AGG
        IBIT GBTC ETHE
      ]

      is_fund_transaction = fund_patterns.any? { |p| description.include?(p) } ||
                            fund_ticker_patterns.any? { |t| description.include?(t) }

      if is_fund_transaction
        if is_retirement_plan && amount.negative?
          # Negative amount in retirement plan = payroll contribution buying shares
          return "Contribution"
        else
          return amount.positive? ? "Buy" : "Sell"
        end
      end

      nil # Unknown - user can set manually
    end

    def detect_holdings_changes(previous, current)
      changes = []

      current.each do |holding|
        prev = find_previous_holding(previous, holding)

        if prev.nil?
          # New holding appeared = BUY
          changes << {
            type: :buy,
            symbol: holding_symbol(holding),
            description: holding_description(holding),
            shares: holding_shares(holding),
            cost_basis: holding_cost_basis(holding),
            created_at: holding_created_at(holding)
          }
        elsif holding_shares(holding) > prev_shares(prev)
          # Shares increased = BUY
          changes << {
            type: :buy,
            symbol: holding_symbol(holding),
            description: holding_description(holding),
            shares_delta: holding_shares(holding) - prev_shares(prev),
            cost_basis_delta: holding_cost_basis(holding) - prev_cost_basis(prev)
          }
        elsif holding_shares(holding) < prev_shares(prev)
          # Shares decreased = SELL
          changes << {
            type: :sell,
            symbol: holding_symbol(holding),
            description: holding_description(holding),
            shares_delta: prev_shares(prev) - holding_shares(holding)
          }
        end
      end

      # Check for holdings that completely disappeared = SELL ALL
      previous.each do |prev|
        unless current.any? { |h| same_holding?(h, prev) }
          changes << {
            type: :sell,
            symbol: prev_symbol(prev),
            description: prev_description(prev),
            shares: prev_shares(prev)
          }
        end
      end

      changes
    end

    def find_matching_entry(change, transactions)
      transactions.each do |txn|
        entry = txn.respond_to?(:entry) ? txn.entry : txn
        next unless entry
        next if entry.exclude_from_cashflow? # Already excluded

        # Match by cost_basis amount (for buys with known cost)
        if change[:cost_basis].present? && change[:cost_basis].to_d > 0
          amount_diff = (entry.amount.to_d.abs - change[:cost_basis].to_d.abs).abs
          return entry if amount_diff < 0.01
        end

        # Match by cost_basis delta (for additional buys)
        if change[:cost_basis_delta].present? && change[:cost_basis_delta].to_d > 0
          amount_diff = (entry.amount.to_d.abs - change[:cost_basis_delta].to_d.abs).abs
          return entry if amount_diff < 0.01
        end

        # Match by description containing security name/symbol
        entry_desc = entry.name&.downcase || ""

        if change[:symbol].present?
          return entry if entry_desc.include?(change[:symbol].downcase)
        end

        if change[:description].present?
          # Match first few words of description for fuzzy matching
          desc_words = change[:description].downcase.split.first(3).join(" ")
          return entry if desc_words.present? && entry_desc.include?(desc_words)
        end
      end

      nil
    end

    def find_previous_holding(previous, current)
      symbol = holding_symbol(current)
      return previous.find { |p| prev_symbol(p) == symbol } if symbol.present?

      # Fallback to description matching if no symbol
      desc = holding_description(current)
      previous.find { |p| prev_description(p) == desc } if desc.present?
    end

    def same_holding?(current, previous)
      current_symbol = holding_symbol(current)
      prev_sym = prev_symbol(previous)

      if current_symbol.present? && prev_sym.present?
        current_symbol == prev_sym
      else
        holding_description(current) == prev_description(previous)
      end
    end

    def save_holdings_snapshot(holdings)
      snapshot_data = holdings.map do |h|
        {
          "symbol" => holding_symbol(h),
          "description" => holding_description(h),
          "shares" => holding_shares(h).to_s,
          "cost_basis" => holding_cost_basis(h).to_s,
          "market_value" => holding_market_value(h).to_s
        }
      end

      @account.update!(
        holdings_snapshot_data: snapshot_data,
        holdings_snapshot_at: Time.current
      )
    end

    # Normalize access - holdings could be AR objects or hashes from different providers
    def holding_symbol(h)
      h.try(:symbol) || h.try(:ticker) || h["symbol"] || h[:symbol] || h["ticker"] || h[:ticker]
    end

    def holding_description(h)
      h.try(:description) || h.try(:name) || h["description"] || h[:description] || h["name"] || h[:name]
    end

    def holding_shares(h)
      val = h.try(:shares) || h.try(:qty) || h["shares"] || h[:shares] || h["qty"] || h[:qty]
      val.to_d
    end

    def holding_cost_basis(h)
      val = h.try(:cost_basis) || h["cost_basis"] || h[:cost_basis]
      val.to_d
    end

    def holding_market_value(h)
      val = h.try(:market_value) || h.try(:amount) || h["market_value"] || h[:market_value] || h["amount"] || h[:amount]
      val.to_d
    end

    def holding_created_at(h)
      h.try(:created_at) || h["created"] || h[:created] || h["created_at"] || h[:created_at]
    end

    # Previous snapshot accessor methods (snapshot is always a hash)
    def prev_symbol(p)
      p["symbol"] || p[:symbol]
    end

    def prev_description(p)
      p["description"] || p[:description]
    end

    def prev_shares(p)
      (p["shares"] || p[:shares]).to_d
    end

    def prev_cost_basis(p)
      (p["cost_basis"] || p[:cost_basis]).to_d
    end
end
