# Service to apply all active rules to a specific transaction or set of transactions.
# This is used when transactions are manually created or updated, ensuring that
# user-defined rules are applied even outside of sync operations.
#
# This service addresses issue #816: "feat: apply rules on manually created transactions"
# which ensures that user-defined rules are automatically applied when transactions
# are created or edited manually, not just during account sync operations.
#
# Usage:
#   # Apply rules to a single transaction (via Entry)
#   ApplyRulesToTransactionService.new(entry, execution_type: "manual").call
#
#   # Apply rules to multiple transactions
#   ApplyRulesToTransactionService.new([entry1, entry2], execution_type: "manual").call
#
#   # Apply rules to a Transaction object directly
#   ApplyRulesToTransactionService.new(transaction, execution_type: "manual").call
#
#   # Apply rules and ignore attribute locks (for admin operations)
#   ApplyRulesToTransactionService.new(entry, ignore_attribute_locks: true).call
#
# The service will:
# 1. Find all active rules for the transaction's family
# 2. Check which rules match the transaction(s) based on their conditions
# 3. Apply matching rules to the transaction(s)
# 4. Create RuleRun records for tracking
# 5. Return a summary of the operation
#
# Performance considerations:
# - Rules are applied synchronously to ensure immediate effect
# - For bulk operations, consider applying rules in batches
# - Async rule actions (like AI categorization) will still run asynchronously
class ApplyRulesToTransactionService
  attr_reader :transactions, :family, :execution_type

  # @param transactions [Transaction, Array<Transaction>, Entry, Array<Entry>] The transaction(s) or entry/entries to apply rules to
  # @param execution_type [String] The type of execution (default: "manual")
  # @param ignore_attribute_locks [Boolean] Whether to ignore attribute locks when applying rules (default: false)
  def initialize(transactions, execution_type: "manual", ignore_attribute_locks: false)
    @transactions = normalize_transactions(transactions)
    @family = extract_family(@transactions.first)
    @execution_type = execution_type
    @ignore_attribute_locks = ignore_attribute_locks
  end

  # Apply all active rules to the specified transaction(s)
  # @return [Hash] Summary of rules applied and results with the following keys:
  #   - transactions_count: Number of transactions processed
  #   - rules_applied: Number of rules successfully applied
  #   - rules_matched: Number of rules that matched at least one transaction
  #   - transactions_modified: Total number of transactions modified by rules
  #   - errors: Array of error hashes with rule_id, rule_name, and error message
  #   - execution_time_ms: Time taken to execute (in milliseconds)
  def call
    start_time = Time.current
    
    return empty_result if transactions.empty? || family.nil?

    active_rules = family.rules.where(active: true, resource_type: "transaction")
    return empty_result.merge(execution_time_ms: 0) if active_rules.empty?

    results = {
      transactions_count: transactions.count,
      rules_applied: 0,
      rules_matched: 0,
      transactions_modified: 0,
      errors: [],
      execution_time_ms: 0
    }

    # For each active rule, check if it matches any of our transactions
    # Use find_each for memory efficiency with large rule sets
    active_rules.find_each do |rule|
      begin
        matching_transactions = find_matching_transactions(rule, transactions)
        
        if matching_transactions.any?
          results[:rules_matched] += 1
          
          # Apply the rule to matching transactions
          # We need to scope the rule to only our matching transactions
          rule_result = apply_rule_to_transactions(rule, matching_transactions)
          
          if rule_result[:success]
            results[:rules_applied] += 1
            results[:transactions_modified] += rule_result[:modified_count] || 0
          else
            results[:errors] << {
              rule_id: rule.id,
              rule_name: rule.name,
              error: rule_result[:error]
            }
          end
        end
      rescue ActiveRecord::RecordNotFound => e
        # Handle case where transaction was deleted during processing
        Rails.logger.warn("ApplyRulesToTransactionService: Transaction not found when applying rule #{rule.id}: #{e.message}")
        results[:errors] << {
          rule_id: rule.id,
          rule_name: rule.name,
          error: "Transaction not found: #{e.message}"
        }
      rescue => e
        Rails.logger.error("ApplyRulesToTransactionService: Error applying rule #{rule.id}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        results[:errors] << {
          rule_id: rule.id,
          rule_name: rule.name,
          error: "#{e.class}: #{e.message}"
        }
      end
    end

    # Calculate execution time
    results[:execution_time_ms] = ((Time.current - start_time) * 1000).round(2)
    
    # Log summary if there were errors or if processing took significant time
    if results[:errors].any? || results[:execution_time_ms] > 1000
      Rails.logger.info("ApplyRulesToTransactionService: Processed #{results[:transactions_count]} transactions, " \
                       "matched #{results[:rules_matched]} rules, applied #{results[:rules_applied]} rules, " \
                       "modified #{results[:transactions_modified]} transactions in #{results[:execution_time_ms]}ms")
    end

    results
  end

  private

    def normalize_transactions(input)
      case input
      when Entry
        [input.transaction].compact
      when Array
        input.map { |item| item.is_a?(Entry) ? item.transaction : item }.compact.select { |t| t.is_a?(Transaction) }
      when Transaction
        [input]
      else
        []
      end
    end

    def find_matching_transactions(rule, transactions_to_check)
      # Get the rule's matching scope using send to access private method
      matching_scope = rule.send(:matching_resources_scope)
      
      # Filter to only include our specific transactions
      transaction_ids = transactions_to_check.map(&:id)
      matching_scope.where(id: transaction_ids)
    end

    def apply_rule_to_transactions(rule, matching_transactions)
      return { success: false, error: "No matching transactions" } if matching_transactions.empty?

      total_modified = 0
      total_async_jobs = 0
      has_async = false

      # Create a rule run for tracking
      rule_run = RuleRun.create!(
        rule: rule,
        rule_name: rule.name,
        execution_type: execution_type,
        status: "pending",
        transactions_queued: matching_transactions.count,
        transactions_processed: 0,
        transactions_modified: 0,
        pending_jobs_count: 0,
        executed_at: Time.current
      )

      begin
        # Apply each action in the rule
        rule.actions.each do |action|
          # Scope the action to only our matching transactions
          transaction_scope = Transaction.where(id: matching_transactions.pluck(:id))
          
          result = action.apply(
            transaction_scope,
            ignore_attribute_locks: @ignore_attribute_locks,
            rule_run: rule_run
          )

          if result.is_a?(Hash) && result[:async]
            has_async = true
            total_async_jobs += result[:jobs_count] || 0
            total_modified += result[:modified_count] || 0
          elsif result.is_a?(Integer)
            total_modified += result
          else
            Rails.logger.warn("ApplyRulesToTransactionService: Unexpected result type from action #{action.id}: #{result.class}")
          end
        end

        # Update rule run status
        if has_async
          rule_run.update!(
            status: "pending",
            transactions_processed: total_modified,
            transactions_modified: total_modified,
            pending_jobs_count: total_async_jobs
          )
        else
          rule_run.update!(
            status: "success",
            transactions_processed: matching_transactions.count,
            transactions_modified: total_modified,
            pending_jobs_count: 0
          )
        end

        { success: true, modified_count: total_modified, async: has_async, jobs_count: total_async_jobs }
      rescue => e
        rule_run.update!(
          status: "failed",
          error_message: "#{e.class}: #{e.message}"
        )
        { success: false, error: e.message }
      end
    end

    def extract_family(transaction)
      return nil unless transaction
      
      # Transactions access family through entry -> account -> family
      if transaction.respond_to?(:entry) && transaction.entry
        transaction.entry.account&.family
      elsif transaction.respond_to?(:account) && transaction.account
        transaction.account.family
      else
        # Fallback: try to find entry for this transaction
        entry = Entry.find_by(entryable: transaction)
        entry&.account&.family
      end
    end

    def empty_result
      {
        transactions_count: 0,
        rules_applied: 0,
        rules_matched: 0,
        transactions_modified: 0,
        errors: [],
        execution_time_ms: 0
      }
    end
end

