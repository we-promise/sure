class Family::DataImporter
  SUPPORTED_TYPES = %w[Account Category Tag Merchant Transaction Trade Valuation Budget BudgetCategory].freeze
  ACCOUNTABLE_TYPES = Accountable::TYPES.freeze

  # Accountable attributes that should be copied from export data (beyond subtype/locked_attributes)
  ACCOUNTABLE_IMPORT_ATTRS = {
    "CreditCard" => %w[available_credit minimum_payment apr annual_fee],
    "Property" => %w[year_built area_value area_unit],
    "Loan" => %w[rate_type interest_rate term_months initial_balance],
    "Vehicle" => %w[year mileage_value mileage_unit make model],
    "Crypto" => %w[tax_treatment]
  }.freeze

  def initialize(family, ndjson_content)
    @family = family
    @ndjson_content = ndjson_content
    @id_mappings = {
      accounts: {},
      categories: {},
      tags: {},
      merchants: {},
      budgets: {},
      securities: {}
    }
    @created_accounts = []
    @created_entries = []
    @errors = []
  end

  def import!
    records = parse_ndjson

    Import.transaction do
      # Accounts must all succeed — everything else depends on them
      import_accounts(records["Account"] || [])

      # Standalone resources: lenient — skip individual failures, keep going
      import_standalone(:categories, records["Category"] || []) { |r| import_single_category(r) }
      link_category_parents
      import_standalone(:tags, records["Tag"] || []) { |r| import_single_tag(r) }
      import_standalone(:merchants, records["Merchant"] || []) { |r| import_single_merchant(r) }

      # Batch sections: all-or-nothing per section via savepoint
      import_batch(:transactions, records["Transaction"] || []) { |recs| import_all_transactions(recs) }
      import_batch(:trades, records["Trade"] || []) { |recs| import_all_trades(recs) }
      import_batch(:valuations, records["Valuation"] || []) { |recs| import_all_valuations(recs) }

      # Budgets: standalone (no financial impact if one month is missing)
      import_standalone(:budgets, records["Budget"] || []) { |r| import_single_budget(r) }
      import_standalone(:budget_categories, records["BudgetCategory"] || []) { |r| import_single_budget_category(r) }
    end

    {
      accounts: @created_accounts,
      entries: @created_entries,
      category_ids: @id_mappings[:categories].values,
      tag_ids: @id_mappings[:tags].values,
      merchant_ids: @id_mappings[:merchants].values,
      budget_ids: @id_mappings[:budgets].values,
      errors: @errors
    }
  end

  private

    def parse_ndjson
      records = Hash.new { |h, k| h[k] = [] }

      @ndjson_content.each_line do |line|
        next if line.strip.empty?

        begin
          record = JSON.parse(line)
          type = record["type"]
          next unless SUPPORTED_TYPES.include?(type)

          records[type] << record
        rescue JSON::ParserError
          # Skip invalid lines
        end
      end

      records
    end

    # ── Error handling helpers ──────────────────────────────────────────

    # Standalone resources: try each record individually, skip on failure.
    # Good for categories, tags, merchants — one failure shouldn't block the rest.
    def import_standalone(section, records, &block)
      records.each do |record|
        block.call(record)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        label = record.dig("data", "name") || record.dig("data", "id") || "unknown"
        @errors << { section: section, record: label, error: e.message }
      end
    end

    # Batch sections: all-or-nothing via savepoint.
    # If ANY record fails, the entire section rolls back and the error is recorded.
    # Good for transactions/trades/valuations — partial import is worse than none.
    def import_batch(section, records, &block)
      return if records.empty?

      Import.transaction(requires_new: true) do
        block.call(records)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      @errors << { section: section, record: "entire section (#{records.size} records)", error: e.message }
    end

    # ── Accounts (must succeed) ────────────────────────────────────────

    def import_accounts(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]
        accountable_data = data["accountable"] || {}
        accountable_type = data["accountable_type"]

        next unless ACCOUNTABLE_TYPES.include?(accountable_type)

        accountable_class = accountable_type.constantize
        accountable = accountable_class.new

        %w[subtype locked_attributes].each do |attr|
          if accountable.respond_to?("#{attr}=") && accountable_data[attr].present?
            accountable.send("#{attr}=", accountable_data[attr])
          end
        end

        (ACCOUNTABLE_IMPORT_ATTRS[accountable_type] || []).each do |attr|
          if accountable.respond_to?("#{attr}=") && !accountable_data[attr].nil?
            accountable.send("#{attr}=", accountable_data[attr])
          end
        end

        account = @family.accounts.build(
          name: data["name"],
          balance: data["balance"].to_d,
          cash_balance: data["cash_balance"]&.to_d || data["balance"].to_d,
          currency: data["currency"] || @family.currency,
          classification: data["classification"],
          accountable: accountable,
          subtype: data["subtype"],
          institution_name: data["institution_name"],
          institution_domain: data["institution_domain"],
          notes: data["notes"],
          status: "active"
        )

        account.save!

        @id_mappings[:accounts][old_id] = account.id
        @created_accounts << account
      end
    end

    # ── Standalone: categories, tags, merchants ────────────────────────

    def import_single_category(record)
      data = record["data"]
      old_id = data["id"]

      # Store parent mapping for second pass (set as instance var)
      @category_parent_mappings ||= {}
      @category_parent_mappings[old_id] = data["parent_id"] if data["parent_id"].present?

      category = @family.categories.find_or_initialize_by(name: data["name"])
      category.assign_attributes(
        color: data["color"] || Category::UNCATEGORIZED_COLOR,
        classification_unused: data["classification_unused"] || data["classification"] || "expense",
        lucide_icon: data["lucide_icon"] || "shapes"
      )
      category.save!

      @id_mappings[:categories][old_id] = category.id
    end

    def link_category_parents
      (@category_parent_mappings || {}).each do |old_id, old_parent_id|
        new_id = @id_mappings[:categories][old_id]
        new_parent_id = @id_mappings[:categories][old_parent_id]
        next unless new_id && new_parent_id

        category = @family.categories.find_by(id: new_id)
        category&.update(parent_id: new_parent_id)
      end
    end

    def import_single_tag(record)
      data = record["data"]
      old_id = data["id"]

      tag = @family.tags.find_or_initialize_by(name: data["name"])
      tag.color = data["color"] || tag.color || Tag::COLORS.sample
      tag.save!

      @id_mappings[:tags][old_id] = tag.id
    end

    def import_single_merchant(record)
      data = record["data"]
      old_id = data["id"]

      merchant = @family.merchants.find_or_initialize_by(name: data["name"])
      merchant.assign_attributes(
        color: data["color"] || merchant.color,
        logo_url: data["logo_url"] || merchant.logo_url
      )
      merchant.save!

      @id_mappings[:merchants][old_id] = merchant.id
    end

    # ── Batch: transactions ────────────────────────────────────────────

    def import_all_transactions(records)
      records.each do |record|
        data = record["data"]

        new_account_id = @id_mappings[:accounts][data["account_id"]]
        next unless new_account_id

        account = @family.accounts.find(new_account_id)

        new_category_id = data["category_id"].present? ? @id_mappings[:categories][data["category_id"]] : nil
        new_merchant_id = data["merchant_id"].present? ? @id_mappings[:merchants][data["merchant_id"]] : nil
        new_tag_ids = Array(data["tag_ids"]).filter_map { |old_tag_id| @id_mappings[:tags][old_tag_id] }

        transaction = Transaction.new(
          category_id: new_category_id,
          merchant_id: new_merchant_id,
          kind: data["kind"] || "standard"
        )

        entry = Entry.new(
          account: account,
          date: Date.parse(data["date"].to_s),
          amount: data["amount"].to_d,
          name: data["name"] || "Imported transaction",
          currency: data["currency"] || account.currency,
          notes: data["notes"],
          excluded: data["excluded"] || false,
          entryable: transaction
        )

        entry.save!

        new_tag_ids.each do |tag_id|
          transaction.taggings.create!(tag_id: tag_id)
        end

        @created_entries << entry
      end
    end

    # ── Batch: trades ──────────────────────────────────────────────────

    def import_all_trades(records)
      records.each do |record|
        data = record["data"]

        new_account_id = @id_mappings[:accounts][data["account_id"]]
        next unless new_account_id

        account = @family.accounts.find(new_account_id)

        ticker = data["ticker"]
        next unless ticker.present?

        security = find_or_create_security(ticker, data["currency"])

        trade = Trade.new(
          security: security,
          qty: data["qty"].to_d,
          price: data["price"].to_d,
          currency: data["currency"] || account.currency
        )

        entry = Entry.new(
          account: account,
          date: Date.parse(data["date"].to_s),
          amount: data["amount"].to_d,
          name: "#{data["qty"].to_d >= 0 ? 'Buy' : 'Sell'} #{ticker}",
          currency: data["currency"] || account.currency,
          entryable: trade
        )

        entry.save!
        @created_entries << entry
      end
    end

    # ── Batch: valuations ──────────────────────────────────────────────

    def import_all_valuations(records)
      records.each do |record|
        data = record["data"]

        new_account_id = @id_mappings[:accounts][data["account_id"]]
        next unless new_account_id

        account = @family.accounts.find(new_account_id)

        valuation = Valuation.new

        entry = Entry.new(
          account: account,
          date: Date.parse(data["date"].to_s),
          amount: data["amount"].to_d,
          name: data["name"] || "Valuation",
          currency: data["currency"] || account.currency,
          entryable: valuation
        )

        entry.save!
        @created_entries << entry
      end
    end

    # ── Standalone: budgets ────────────────────────────────────────────

    def import_single_budget(record)
      data = record["data"]
      old_id = data["id"]

      budget = @family.budgets.build(
        start_date: Date.parse(data["start_date"].to_s),
        end_date: Date.parse(data["end_date"].to_s),
        budgeted_spending: data["budgeted_spending"]&.to_d,
        expected_income: data["expected_income"]&.to_d,
        currency: data["currency"] || @family.currency
      )

      budget.save!
      @id_mappings[:budgets][old_id] = budget.id
    end

    def import_single_budget_category(record)
      data = record["data"]

      new_budget_id = @id_mappings[:budgets][data["budget_id"]]
      return unless new_budget_id

      new_category_id = @id_mappings[:categories][data["category_id"]]
      return unless new_category_id

      budget = @family.budgets.find(new_budget_id)

      budget_category = budget.budget_categories.build(
        category_id: new_category_id,
        budgeted_spending: data["budgeted_spending"].to_d,
        currency: data["currency"] || budget.currency
      )

      budget_category.save!
    end

    # ── Helpers ────────────────────────────────────────────────────────

    def find_or_create_security(ticker, currency)
      cache_key = "#{ticker}:#{currency}"
      return @id_mappings[:securities][cache_key] if @id_mappings[:securities][cache_key]

      security = Security.find_by(ticker: ticker.upcase)
      security ||= Security.create!(
        ticker: ticker.upcase,
        name: ticker.upcase
      )

      @id_mappings[:securities][cache_key] = security
      security
    end
end
