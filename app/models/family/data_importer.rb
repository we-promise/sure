class Family::DataImporter
  SUPPORTED_TYPES = %w[Account Category Tag Merchant Transaction Trade Valuation Budget BudgetCategory Rule].freeze
  ACCOUNTABLE_TYPES = Accountable::TYPES.freeze

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
  end

  def import!
    records = parse_ndjson

    Import.transaction do
      # Import in dependency order
      import_accounts(records["Account"] || [])
      import_categories(records["Category"] || [])
      import_tags(records["Tag"] || [])
      import_merchants(records["Merchant"] || [])
      import_transactions(records["Transaction"] || [])
      import_trades(records["Trade"] || [])
      import_valuations(records["Valuation"] || [])
      import_budgets(records["Budget"] || [])
      import_budget_categories(records["BudgetCategory"] || [])
      import_rules(records["Rule"] || [])
    end

    { accounts: @created_accounts, entries: @created_entries }
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

    def import_accounts(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]
        accountable_data = data["accountable"] || {}
        accountable_type = data["accountable_type"]

        # Skip if accountable type is not valid
        next unless ACCOUNTABLE_TYPES.include?(accountable_type)

        # Build accountable
        accountable_class = accountable_type.constantize
        accountable = accountable_class.new
        accountable.subtype = accountable_data["subtype"] if accountable.respond_to?(:subtype=) && accountable_data["subtype"]

        # Copy any other accountable attributes
        safe_accountable_attrs = %w[subtype locked_attributes]
        safe_accountable_attrs.each do |attr|
          if accountable.respond_to?("#{attr}=") && accountable_data[attr].present?
            accountable.send("#{attr}=", accountable_data[attr])
          end
        end

        account = @family.accounts.build(
          name: data["name"],
          balance: data["balance"].to_d,
          cash_balance: data["cash_balance"]&.to_d || data["balance"].to_d,
          currency: data["currency"] || @family.currency,
          accountable: accountable,
          subtype: data["subtype"],
          institution_name: data["institution_name"],
          institution_domain: data["institution_domain"],
          notes: data["notes"],
          status: "active"
        )

        account.save!

        # Set opening balance if we have a historical balance
        if data["balance"].present?
          manager = Account::OpeningBalanceManager.new(account)
          manager.set_opening_balance(balance: data["balance"].to_d)
        end

        @id_mappings[:accounts][old_id] = account.id
        @created_accounts << account
      end
    end

    def import_categories(records)
      # First pass: create all categories without parent relationships
      parent_mappings = {}

      records.each do |record|
        data = record["data"]
        old_id = data["id"]
        parent_id = data["parent_id"]

        # Store parent relationship for second pass
        parent_mappings[old_id] = parent_id if parent_id.present?

        category = @family.categories.build(
          name: data["name"],
          color: data["color"] || Category::UNCATEGORIZED_COLOR,
          classification: data["classification"] || "expense",
          lucide_icon: data["lucide_icon"] || "shapes"
        )

        category.save!
        @id_mappings[:categories][old_id] = category.id
      end

      # Second pass: establish parent relationships
      parent_mappings.each do |old_id, old_parent_id|
        new_id = @id_mappings[:categories][old_id]
        new_parent_id = @id_mappings[:categories][old_parent_id]

        next unless new_id && new_parent_id

        category = @family.categories.find(new_id)
        category.update!(parent_id: new_parent_id)
      end
    end

    def import_tags(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

        tag = @family.tags.build(
          name: data["name"],
          color: data["color"] || Tag::COLORS.sample
        )

        tag.save!
        @id_mappings[:tags][old_id] = tag.id
      end
    end

    def import_merchants(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

        merchant = @family.merchants.build(
          name: data["name"],
          color: data["color"],
          logo_url: data["logo_url"]
        )

        merchant.save!
        @id_mappings[:merchants][old_id] = merchant.id
      end
    end

    def import_transactions(records)
      records.each do |record|
        data = record["data"]

        # Map account ID
        new_account_id = @id_mappings[:accounts][data["account_id"]]
        next unless new_account_id

        account = @family.accounts.find(new_account_id)

        # Map category ID (optional)
        new_category_id = nil
        if data["category_id"].present?
          new_category_id = @id_mappings[:categories][data["category_id"]]
        end

        # Map merchant ID (optional)
        new_merchant_id = nil
        if data["merchant_id"].present?
          new_merchant_id = @id_mappings[:merchants][data["merchant_id"]]
        end

        # Map tag IDs (optional)
        new_tag_ids = []
        if data["tag_ids"].present?
          new_tag_ids = Array(data["tag_ids"]).map { |old_tag_id| @id_mappings[:tags][old_tag_id] }.compact
        end

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

        # Add tags through the tagging association
        new_tag_ids.each do |tag_id|
          transaction.taggings.create!(tag_id: tag_id)
        end

        @created_entries << entry
      end
    end

    def import_trades(records)
      records.each do |record|
        data = record["data"]

        # Map account ID
        new_account_id = @id_mappings[:accounts][data["account_id"]]
        next unless new_account_id

        account = @family.accounts.find(new_account_id)

        # Resolve or create security
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

    def import_valuations(records)
      records.each do |record|
        data = record["data"]

        # Map account ID
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

    def import_budgets(records)
      records.each do |record|
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
    end

    def import_budget_categories(records)
      records.each do |record|
        data = record["data"]

        # Map budget ID
        new_budget_id = @id_mappings[:budgets][data["budget_id"]]
        next unless new_budget_id

        # Map category ID
        new_category_id = @id_mappings[:categories][data["category_id"]]
        next unless new_category_id

        budget = @family.budgets.find(new_budget_id)

        budget_category = budget.budget_categories.build(
          category_id: new_category_id,
          budgeted_spending: data["budgeted_spending"].to_d,
          currency: data["currency"] || budget.currency
        )

        budget_category.save!
      end
    end

    def import_rules(records)
      records.each do |record|
        data = record["data"]

        rule = @family.rules.build(
          name: data["name"],
          resource_type: data["resource_type"] || "transaction",
          active: data["active"] || false,
          effective_date: data["effective_date"].present? ? Date.parse(data["effective_date"].to_s) : nil
        )

        # Build conditions
        (data["conditions"] || []).each do |condition_data|
          build_rule_condition(rule, condition_data)
        end

        # Build actions
        (data["actions"] || []).each do |action_data|
          build_rule_action(rule, action_data)
        end

        rule.save!
      end
    end

    def build_rule_condition(rule, condition_data, parent: nil)
      value = resolve_rule_condition_value(condition_data)

      condition = if parent
        parent.sub_conditions.build(
          condition_type: condition_data["condition_type"],
          operator: condition_data["operator"],
          value: value
        )
      else
        rule.conditions.build(
          condition_type: condition_data["condition_type"],
          operator: condition_data["operator"],
          value: value
        )
      end

      # Handle nested sub_conditions for compound conditions
      (condition_data["sub_conditions"] || []).each do |sub_condition_data|
        build_rule_condition(rule, sub_condition_data, parent: condition)
      end

      condition
    end

    def build_rule_action(rule, action_data)
      value = resolve_rule_action_value(action_data)

      rule.actions.build(
        action_type: action_data["action_type"],
        value: value
      )
    end

    def resolve_rule_condition_value(condition_data)
      condition_type = condition_data["condition_type"]
      value = condition_data["value"]

      return value unless value.present?

      # Map category names to IDs
      if condition_type == "transaction_category"
        category = @family.categories.find_by(name: value)
        category ||= @family.categories.create!(
          name: value,
          color: Category::UNCATEGORIZED_COLOR,
          classification: "expense",
          lucide_icon: "shapes"
        )
        return category.id
      end

      # Map merchant names to IDs
      if condition_type == "transaction_merchant"
        merchant = @family.merchants.find_by(name: value)
        merchant ||= @family.merchants.create!(name: value)
        return merchant.id
      end

      value
    end

    def resolve_rule_action_value(action_data)
      action_type = action_data["action_type"]
      value = action_data["value"]

      return value unless value.present?

      # Map category names to IDs
      if action_type == "set_transaction_category"
        category = @family.categories.find_by(name: value)
        category ||= @family.categories.create!(
          name: value,
          color: Category::UNCATEGORIZED_COLOR,
          classification: "expense",
          lucide_icon: "shapes"
        )
        return category.id
      end

      # Map merchant names to IDs
      if action_type == "set_transaction_merchant"
        merchant = @family.merchants.find_by(name: value)
        merchant ||= @family.merchants.create!(name: value)
        return merchant.id
      end

      # Map tag names to IDs
      if action_type == "set_transaction_tags"
        tag = @family.tags.find_by(name: value)
        tag ||= @family.tags.create!(name: value)
        return tag.id
      end

      value
    end

    def find_or_create_security(ticker, currency)
      # Check cache first
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
