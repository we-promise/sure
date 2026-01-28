# SimpleFin Investment transactions processor
#
# NOTE: SimpleFIN transactions (dividends, contributions, etc.) for investment accounts
# are already processed by SimplefinAccount::Transactions::Processor, which handles ALL
# account types including investments. That processor uses SimplefinEntry::Processor
# which captures full metadata (merchant, notes, extra data).
#
# This processor is intentionally a no-op for transactions to avoid:
# 1. Duplicate processing of the same transactions
# 2. Overwriting richer data with less complete data
#
# Unlike Plaid (which has a separate investment_transactions endpoint), SimpleFIN returns
# all transactions in a single `transactions` array regardless of account type.
#
# Holdings are processed separately by SimplefinAccount::Investments::HoldingsProcessor.
class SimplefinAccount::Investments::TransactionsProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    # Intentionally a no-op for transactions.
    # SimpleFIN investment transactions are already processed by the regular
    # SimplefinAccount::Transactions::Processor which handles all account types.
    #
    # This avoids duplicate processing and ensures the richer metadata from
    # SimplefinEntry::Processor (merchant, notes, extra) is preserved.
    Rails.logger.debug "SimplefinAccount::Investments::TransactionsProcessor - Skipping (transactions handled by SimplefinAccount::Transactions::Processor)"
  end

  private
    attr_reader :simplefin_account
end
