# frozen_string_literal: true

module BankdataImport
  class RowValidator
    REQUIRED_TRANSACTION_FIELDS = %w[external_id source_transaction_id source_account_key date amount currency name income_expense extra].freeze

    Result = Struct.new(:valid, :errors, :account_mappings, :transactions, :items, keyword_init: true) do
      def valid? = valid
    end

    def initialize(family:, payload:)
      @family = family
      @payload = payload || {}
      @errors = []
      @items = []
      @account_mappings = {}
    end

    def call
      validate_request_shape
      validate_source
      validate_account_mappings if payload["account_mappings"].is_a?(Array)
      validate_transactions if payload["transactions"].is_a?(Array)

      Result.new(valid: errors.empty?, errors: errors, account_mappings: account_mappings, transactions: transactions, items: items)
    end

    private
      attr_reader :family, :payload, :errors, :items, :account_mappings

      def transactions
        Array(payload["transactions"])
      end

      def validate_request_shape
        errors << "source is required" unless payload.key?("source")
        errors << "account_mappings is required" unless payload["account_mappings"].is_a?(Array)
        errors << "transactions is required" unless payload["transactions"].is_a?(Array)
      end

      def validate_source
        return if payload["source"].blank? || payload["source"] == SOURCE

        errors << "source must be #{SOURCE}"
      end

      def validate_account_mappings
        payload["account_mappings"].each do |mapping|
          source_key = mapping["source_account_key"].to_s
          account = family.accounts.find_by(id: mapping["sure_account_id"])

          if source_key.blank? || account.nil?
            errors << "account mapping #{source_key.presence || '(blank)'} does not reference an accessible account"
            next
          end

          account_mappings[source_key] = account
        end
      end

      def validate_transactions
        seen = Set.new

        transactions.each do |transaction|
          missing = REQUIRED_TRANSACTION_FIELDS.select { |field| transaction[field].blank? && transaction[field] != false }
          duplicate = seen.include?(transaction["external_id"])
          seen << transaction["external_id"]

          if duplicate
            errors << "duplicate external_id #{transaction['external_id']}"
          end

          if missing.any?
            items << item_for(transaction, :invalid, "missing fields: #{missing.join(', ')}")
          elsif transaction["category_name"].blank? && !allow_uncategorized?
            items << item_for(transaction, :uncategorized, "category_name is required for import")
          else
            items << item_for(transaction, :ready)
          end
        end
      end

      def allow_uncategorized?
        ActiveModel::Type::Boolean.new.cast(payload["allow_uncategorized"])
      end

      def item_for(transaction, status, reason = nil)
        {
          source_transaction_id: transaction["source_transaction_id"],
          external_id: transaction["external_id"],
          status: status.to_s,
          amount: transaction["amount"],
          income_expense: transaction["income_expense"],
          category_name: transaction["category_name"],
          reason: reason
        }.compact
      end
  end
end
