# frozen_string_literal: true

module BankdataImport
  class AppendOnlyImporter
    def initialize(family:, payload:, mode:)
      @family = family
      @payload = payload
      @mode = mode.to_sym
    end

    def call
      validation = RowValidator.new(family: family, payload: payload).call
      raise ValidationError.new(validation.errors) unless validation.valid?

      category_resolver = CategoryResolver.new(family)
      merchant_resolver = MerchantResolver.new(family)
      results = []

      payload.fetch("transactions", []).each_with_index do |transaction, index|
        validation_item = validation.items[index]
        if validation_item[:status] != "ready"
          results << validation_item
          next
        end

        account = validation.account_mappings.fetch(transaction["source_account_key"])
        existing = account.entries.find_by(source: SOURCE, external_id: transaction["external_id"])

        if existing
          results << item_for(transaction, :already_imported, entry: existing)
          next
        end

        if mode == :preview
          results << item_for(transaction, :created)
          next
        end

        category = resolve_category(category_resolver, transaction)
        merchant = merchant_resolver.resolve(transaction["merchant_name"])
        entry = create_entry!(account, transaction, category, merchant)
        results << item_for(transaction, :created, entry: entry)
      rescue StandardError => error
        results << item_for(transaction, :failed, reason: error.message)
      end

      SyncSummary.new(results)
    end

    private
      attr_reader :family, :payload, :mode

      def resolve_category(category_resolver, transaction)
        return nil if transaction["category_name"].blank?

        category_resolver.resolve(parent_name: transaction["category_parent_name"], category_name: transaction["category_name"])
      end

      def create_entry!(account, transaction, category, merchant)
        account.entries.create!(
          name: transaction["name"],
          amount: BigDecimal(transaction["amount"].to_s),
          currency: transaction["currency"],
          date: Date.iso8601(transaction["date"]),
          excluded: ActiveModel::Type::Boolean.new.cast(transaction["excluded"]),
          source: SOURCE,
          external_id: transaction["external_id"],
          import_locked: true,
          entryable: Transaction.new(
            category: category,
            merchant: merchant,
            extra: transaction["extra"] || {}
          )
        )
      end

      def item_for(transaction, status, entry: nil, reason: nil)
        {
          source_transaction_id: transaction["source_transaction_id"],
          external_id: transaction["external_id"],
          status: status.to_s,
          amount: transaction["amount"],
          income_expense: transaction["income_expense"],
          category_name: transaction["category_name"],
          entry_id: entry&.id,
          reason: reason
        }.compact
      end
  end
end
