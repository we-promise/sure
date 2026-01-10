# Processes stored transactions for a CoinStats account.
# Filters transactions by token and delegates to entry processor.
class CoinstatsAccount::Transactions::Processor
  include CoinstatsTransactionIdentifiable

  attr_reader :coinstats_account

  # @param coinstats_account [CoinstatsAccount] Account with transactions to process
  def initialize(coinstats_account)
    @coinstats_account = coinstats_account
  end

  # Processes all stored transactions for this account.
  # Filters to relevant token and imports each transaction.
  # @return [Hash] Result with :success, :total, :imported, :failed, :errors
  def process
    unless coinstats_account.raw_transactions_payload.present?
      Rails.logger.info "CoinstatsAccount::Transactions::Processor - No transactions in raw_transactions_payload for coinstats_account #{coinstats_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    # Filter transactions to only include ones for this specific token
    # Multiple coinstats_accounts can share the same wallet address (one per token)
    # but we only want to process transactions relevant to this token
    relevant_transactions = filter_transactions_for_account(coinstats_account.raw_transactions_payload)

    total_count = relevant_transactions.count
    Rails.logger.info "CoinstatsAccount::Transactions::Processor - Processing #{total_count} transactions for coinstats_account #{coinstats_account.id} (#{coinstats_account.name})"

    imported_count = 0
    failed_count = 0
    errors = []

    relevant_transactions.each_with_index do |transaction_data, index|
      begin
        result = CoinstatsEntry::Processor.new(
          transaction_data,
          coinstats_account: coinstats_account
        ).process

        if result.nil?
          failed_count += 1
          transaction_id = extract_coinstats_transaction_id(transaction_data)
          errors << { index: index, transaction_id: transaction_id, error: "No linked account" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        failed_count += 1
        transaction_id = extract_coinstats_transaction_id(transaction_data)
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "CoinstatsAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        failed_count += 1
        transaction_id = extract_coinstats_transaction_id(transaction_data)
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "CoinstatsAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "CoinstatsAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "CoinstatsAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end

  private

    # Filters transactions to only include ones for this specific token.
    # CoinStats returns all wallet transactions, but each CoinstatsAccount
    # represents a single token, so we filter by matching coin ID or symbol.
    # @param transactions [Array<Hash>] Raw transactions from storage
    # @return [Array<Hash>] Transactions matching this account's token
    def filter_transactions_for_account(transactions)
      return [] unless transactions.present?
      return transactions unless coinstats_account.account_id.present?

      account_id = coinstats_account.account_id.to_s.downcase

      transactions.select do |tx|
        tx = tx.with_indifferent_access

        # Check coin ID in transactions[0].items[0].coin.id (most common location)
        coin_id = tx.dig(:transactions, 0, :items, 0, :coin, :id)&.to_s&.downcase

        # Also check coinData for symbol match as fallback
        coin_symbol = tx.dig(:coinData, :symbol)&.to_s&.downcase

        # Match if coin ID equals account_id, or if symbol matches account name precisely.
        # We use strict matching to avoid false positives (e.g., "ETH" should not match
        # "Ethereum Classic" which has symbol "ETC"). The symbol must appear as:
        # - A whole word (bounded by word boundaries), OR
        # - Inside parentheses like "(ETH)" which is common in wallet naming conventions
        coin_id == account_id ||
          (coin_symbol.present? && symbol_matches_name?(coin_symbol, coinstats_account.name))
      end
    end

    # Checks if a coin symbol matches the account name using strict matching.
    # Avoids false positives from partial substring matches (e.g., "ETH" matching
    # "Ethereum Classic (0x123...)" which should only match "ETC").
    #
    # @param symbol [String] The coin symbol to match (already downcased)
    # @param name [String, nil] The account name to match against
    # @return [Boolean] true if symbol matches name precisely
    def symbol_matches_name?(symbol, name)
      return false if name.blank?

      normalized_name = name.to_s.downcase

      # Match symbol as a whole word using word boundaries, or within parentheses.
      # Examples that SHOULD match:
      #   - "ETH" matches "ETH Wallet", "My ETH", "Ethereum (ETH)"
      #   - "BTC" matches "BTC", "(BTC) Savings", "Bitcoin (BTC)"
      # Examples that should NOT match:
      #   - "ETH" should NOT match "Ethereum Classic" (symbol is "ETC")
      #   - "ETH" should NOT match "WETH Wrapped" (different token)
      #   - "BTC" should NOT match "BTCB" (different token)
      word_boundary_pattern = /\b#{Regexp.escape(symbol)}\b/
      parenthesized_pattern = /\(#{Regexp.escape(symbol)}\)/

      word_boundary_pattern.match?(normalized_name) || parenthesized_pattern.match?(normalized_name)
    end
end
