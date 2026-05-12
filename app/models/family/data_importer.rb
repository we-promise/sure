require "set"

class Family::DataImporter
  SUPPORTED_TYPES = %w[Account Balance Category Tag Merchant RecurringTransaction Transaction Transfer RejectedTransfer Trade Holding Valuation Budget BudgetCategory Rule].freeze
  ACCOUNTABLE_TYPES = Accountable::TYPES.freeze

  def initialize(family, ndjson_content)
    @family = family
    @ndjson_content = ndjson_content
    @id_mappings = {
      accounts: {},
      categories: {},
      tags: {},
      merchants: {},
      recurring_transactions: {},
      transactions: {},
      budgets: {},
      securities: {}
    }
    @security_cache = {}
    @created_accounts = []
    @created_entries = []
  end

  def import!
    records = parse_ndjson
    @oldest_import_entry_dates_by_account = oldest_import_entry_dates_by_account(records)
    @imported_opening_anchor_account_ids = imported_opening_anchor_account_ids(records["Valuation"] || [])

    Import.transaction do
      # Import in dependency order
      import_accounts(records["Account"] || [])
      import_balances(records["Balance"] || [])
      import_categories(records["Category"] || [])
      import_tags(records["Tag"] || [])
      import_merchants(records["Merchant"] || [])
      import_recurring_transactions(records["RecurringTransaction"] || [])
      import_transactions(records["Transaction"] || [])
      import_transfers(records["Transfer"] || [])
      import_rejected_transfers(records["RejectedTransfer"] || [])
      import_trades(records["Trade"] || [])
      import_holdings(records["Holding"] || [])
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
          status: importable_account_status(data["status"])
        )

        account.save!

        # Set opening balance if we have a historical balance and the import
        # does not provide an explicit opening-anchor valuation for this account.
        if data["balance"].present? && !@imported_opening_anchor_account_ids.include?(old_id)
          manager = Account::OpeningBalanceManager.new(account)
          result = manager.set_opening_balance(
            balance: data["balance"].to_d,
            date: opening_balance_date_for(old_id, data)
          )
          log_failed_opening_balance_import(account, old_id, result) unless result.success?
        end

        @id_mappings[:accounts][old_id] = account.id
        @created_accounts << account
      end
    end

    def importable_account_status(status)
      status.to_s.in?(%w[active disabled draft]) ? status.to_s : "active"
    end

    def import_balances(records)
      records.each do |record|
        data = record["data"] || {}
        new_account_id = @id_mappings[:accounts][data["account_id"]]
        balance_date = parse_import_date(data["date"])
        next if new_account_id.blank? || balance_date.blank? || data["balance"].blank?

        account = @family.accounts.find(new_account_id)
        currency = data["currency"].presence || account.currency
        balance = account.balances.find_or_initialize_by(date: balance_date, currency: currency)

        balance.assign_attributes(imported_balance_attributes(data))
        balance.save!
      end
    end

    def imported_balance_attributes(data)
      attributes = {
        balance: data["balance"].to_d,
        cash_balance: optional_decimal(data["cash_balance"]),
        start_cash_balance: optional_decimal(data["start_cash_balance"]),
        start_non_cash_balance: optional_decimal(data["start_non_cash_balance"]),
        cash_inflows: optional_decimal(data["cash_inflows"]),
        cash_outflows: optional_decimal(data["cash_outflows"]),
        non_cash_inflows: optional_decimal(data["non_cash_inflows"]),
        non_cash_outflows: optional_decimal(data["non_cash_outflows"]),
        net_market_flows: optional_decimal(data["net_market_flows"]),
        cash_adjustments: optional_decimal(data["cash_adjustments"]),
        non_cash_adjustments: optional_decimal(data["non_cash_adjustments"])
      }.compact

      attributes[:flows_factor] = balance_flows_factor_for(data["flows_factor"]) if data["flows_factor"].present?
      attributes
    end

    def optional_decimal(value)
      value.presence&.to_d
    end

    def balance_flows_factor_for(value)
      value.to_i.in?([ -1, 1 ]) ? value.to_i : 1
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
          classification_unused: data["classification_unused"] || data["classification"] || "expense",
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

    def import_recurring_transactions(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

        new_account_id = remap_optional_id(:accounts, data["account_id"])
        next if data["account_id"].present? && new_account_id.blank?

        new_merchant_id = remap_optional_id(:merchants, data["merchant_id"])
        next if data["merchant_id"].present? && new_merchant_id.blank?

        expected_day_of_month = recurring_expected_day_for(data["expected_day_of_month"])
        next unless expected_day_of_month
        last_occurrence_date = parse_import_date(data["last_occurrence_date"])
        next_expected_date = parse_import_date(data["next_expected_date"])
        next unless last_occurrence_date && next_expected_date

        recurring_transaction = @family.recurring_transactions.build(
          account_id: new_account_id,
          merchant_id: new_merchant_id,
          amount: data["amount"].to_d,
          currency: data["currency"] || @family.currency,
          expected_day_of_month: expected_day_of_month,
          last_occurrence_date: last_occurrence_date,
          next_expected_date: next_expected_date,
          status: recurring_transaction_status_for(data["status"]),
          occurrence_count: data["occurrence_count"].to_i,
          name: data["name"],
          manual: boolean_import_value(data, "manual", default: false),
          expected_amount_min: data["expected_amount_min"]&.to_d,
          expected_amount_max: data["expected_amount_max"]&.to_d,
          expected_amount_avg: data["expected_amount_avg"]&.to_d
        )

        recurring_transaction.save!
        @id_mappings[:recurring_transactions][old_id] = recurring_transaction.id
      end
    end

    def remap_optional_id(mapping_key, old_id)
      return if old_id.blank?

      @id_mappings[mapping_key][old_id]
    end

    def recurring_transaction_status_for(status)
      status.to_s.in?(RecurringTransaction.statuses.keys) ? status.to_s : "active"
    end

    def recurring_expected_day_for(value)
      return if value.blank?

      expected_day = value.to_i
      expected_day if expected_day.between?(1, 31)
    end

    def boolean_import_value(data, key, default:)
      return default unless data.key?(key)

      ActiveModel::Type::Boolean.new.cast(data[key])
    end

    def import_transactions(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

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
        @id_mappings[:transactions][old_id] = transaction.id
      end
    end

    def import_transfers(records)
      records.each do |record|
        data = record["data"]
        inflow_transaction_id = @id_mappings[:transactions][data["inflow_transaction_id"]]
        outflow_transaction_id = @id_mappings[:transactions][data["outflow_transaction_id"]]
        next unless inflow_transaction_id && outflow_transaction_id

        Transfer.find_or_create_by!(
          inflow_transaction_id: inflow_transaction_id,
          outflow_transaction_id: outflow_transaction_id
        ) do |transfer|
          transfer.status = transfer_status_for(data["status"])
          transfer.notes = data["notes"]
        end
      end
    end

    def import_rejected_transfers(records)
      records.each do |record|
        data = record["data"]
        inflow_transaction_id = @id_mappings[:transactions][data["inflow_transaction_id"]]
        outflow_transaction_id = @id_mappings[:transactions][data["outflow_transaction_id"]]
        next unless inflow_transaction_id && outflow_transaction_id

        RejectedTransfer.find_or_create_by!(
          inflow_transaction_id: inflow_transaction_id,
          outflow_transaction_id: outflow_transaction_id
        )
      end
    end

    def transfer_status_for(status)
      status = status.to_s
      return status if Transfer.statuses.key?(status)

      Rails.logger.debug("Unknown transfer status #{status.inspect}; defaulting to pending") if status.present?
      "pending"
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

        security = find_or_create_security(
          ticker,
          data["currency"],
          old_security_id: data["security_id"],
          name: data["security_name"],
          exchange_operating_mic: data["exchange_operating_mic"]
        )

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

    def import_holdings(records)
      accounts_by_id = @family.accounts.where(id: records.filter_map { |record| @id_mappings[:accounts][record.dig("data", "account_id")] }).index_by(&:id)

      records.each do |record|
        data = record["data"]

        new_account_id = @id_mappings[:accounts][data["account_id"]]
        next unless new_account_id

        account = accounts_by_id[new_account_id]
        next unless account

        ticker = data["ticker"]
        next unless ticker.present?

        security = find_or_create_security(
          ticker,
          data["currency"],
          old_security_id: data["security_id"],
          name: data["security_name"],
          exchange_operating_mic: data["exchange_operating_mic"],
          exchange_mic: data["exchange_mic"],
          exchange_acronym: data["exchange_acronym"],
          country_code: data["country_code"],
          kind: data["kind"],
          website_url: data["website_url"]
        )

        holding_date = Date.parse(data["date"].to_s)
        holding_currency = data["currency"] || account.currency
        holding_attributes = {
          qty: data["qty"].to_d,
          price: data["price"].to_d,
          amount: data["amount"].to_d,
          currency: holding_currency,
          cost_basis: data["cost_basis"]&.to_d,
          cost_basis_source: importable_cost_basis_source(data["cost_basis_source"]),
          cost_basis_locked: truthy?(data["cost_basis_locked"]) || false,
          security_locked: truthy?(data["security_locked"]) || false
        }

        upsert_imported_holding!(account, security, holding_date, holding_currency, holding_attributes)
      end
    end

    def import_valuations(records)
      records.each do |record|
        data = record["data"]

        # Map account ID
        new_account_id = @id_mappings[:accounts][data["account_id"]]
        next unless new_account_id

        account = @family.accounts.find(new_account_id)

        valuation = Valuation.new(kind: valuation_kind_for(data["kind"]))

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

    def oldest_import_entry_dates_by_account(records)
      dates_by_account = {}

      # Account-level opening balances must precede every imported account
      # activity, including standalone valuation snapshots.
      %w[Balance Transaction Trade Holding Valuation].each do |type|
        records[type].to_a.each do |record|
          data = record["data"] || {}
          account_id = data["account_id"]
          date = parse_import_date(data["date"])
          next if account_id.blank? || date.blank?

          dates_by_account[account_id] = [ dates_by_account[account_id], date ].compact.min
        end
      end

      dates_by_account
    end

    def imported_opening_anchor_account_ids(records)
      records.each_with_object(Set.new) do |record, account_ids|
        data = record["data"] || {}
        next unless data["kind"].to_s == "opening_anchor"
        next if data["account_id"].blank?

        account_ids.add(data["account_id"])
      end
    end

    def opening_balance_date_for(old_id, data)
      explicit_date = parse_import_date(
        data["opening_balance_date"] || data["opening_balance_on"]
      )

      max_allowed_date = @oldest_import_entry_dates_by_account[old_id]&.prev_day
      [ explicit_date, max_allowed_date ].compact.min
    end

    def log_failed_opening_balance_import(account, old_id, result)
      Rails.logger.warn(
        "Failed to import opening balance for account #{account.id} from source account #{old_id}: #{result.error}"
      )
    end

    def valuation_kind_for(value)
      kind = value.to_s
      Valuation.kinds.key?(kind) ? kind : "reconciliation"
    end

    def parse_import_date(value)
      return if value.blank?

      Date.parse(value.to_s)
    rescue Date::Error
      nil
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
      value = rule_operand_value(condition_data)

      return value unless value.present?

      # Map category names to IDs
      if condition_type == "transaction_category"
        category = @family.categories.find_by(name: value)
        category ||= @family.categories.create!(
          name: value,
          color: Category::UNCATEGORIZED_COLOR,
          classification_unused: "expense",
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
      value = rule_operand_value(action_data)

      return value unless value.present?

      # Map category names to IDs
      if action_type == "set_transaction_category"
        category = @family.categories.find_by(name: value)
        category ||= @family.categories.create!(
          name: value,
          color: Category::UNCATEGORIZED_COLOR,
          classification_unused: "expense",
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

    def rule_operand_value(data)
      raw_value = data["value"]
      value = raw_value.is_a?(String) ? raw_value.presence : raw_value
      value_ref_name = data.dig("value_ref", "name")

      return value_ref_name if value.is_a?(String) && uuid_like?(value) && value_ref_name.present?
      return value unless value.nil?

      value_ref_name
    end

    def uuid_like?(value)
      UuidFormat.valid?(value)
    end

    def importable_cost_basis_source(value)
      source = value.to_s
      Holding::COST_BASIS_SOURCES.include?(source) ? source : nil
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def find_or_create_security(ticker, currency, old_security_id: nil, **attributes)
      # Check cache first
      normalized_ticker = ticker.to_s.upcase
      exchange_operating_mic = attributes[:exchange_operating_mic].presence&.upcase
      cache_key = "#{normalized_ticker}:#{exchange_operating_mic}:#{currency}"

      if @security_cache[cache_key]
        security = @security_cache[cache_key]
        apply_security_metadata(security, normalized_ticker, attributes)
        return security
      end

      if old_security_id.present? && @id_mappings[:securities][old_security_id]
        security = Security.find(@id_mappings[:securities][old_security_id])
        apply_security_metadata(security, normalized_ticker, attributes)
        @security_cache[cache_key] = security
        return security
      end

      security = find_security_by_identity(normalized_ticker, exchange_operating_mic)
      apply_security_metadata(security, normalized_ticker, attributes)

      @security_cache[cache_key] = security
      @id_mappings[:securities][old_security_id] = security.id if old_security_id.present?
      security
    end

    def find_security_by_identity(ticker, exchange_operating_mic)
      if exchange_operating_mic.present?
        return Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: exchange_operating_mic)
      end

      # Without an exchange MIC, matching by ticker is a best-effort restore path and can merge same-ticker securities from different venues.
      Security.find_by(ticker: ticker, exchange_operating_mic: nil) ||
        Security.where(ticker: ticker).order(:created_at).first ||
        Security.new(ticker: ticker)
    end

    def apply_security_metadata(security, ticker, attributes)
      assign_if_blank_or_placeholder(security, :name, attributes[:name].presence, placeholder: ticker)
      assign_if_blank(security, :exchange_operating_mic, attributes[:exchange_operating_mic].presence&.upcase)
      assign_if_blank(security, :exchange_mic, attributes[:exchange_mic].presence)
      assign_if_blank(security, :exchange_acronym, attributes[:exchange_acronym].presence)
      assign_if_blank(security, :country_code, attributes[:country_code].presence)
      assign_if_blank(security, :website_url, attributes[:website_url].presence)
      security.kind = security_kind_for(attributes[:kind]) if security.new_record? || security.kind.blank?

      security.save! if security.new_record? || security.changed?
    end

    def assign_if_blank(record, attribute, value)
      return if value.blank?
      return if record.public_send(attribute).present?

      record.public_send("#{attribute}=", value)
    end

    def assign_if_blank_or_placeholder(record, attribute, value, placeholder:)
      return if value.blank?

      current_value = record.public_send(attribute)
      return if current_value.present? && current_value != placeholder

      record.public_send("#{attribute}=", value)
    end

    def upsert_imported_holding!(account, security, date, currency, attributes)
      holding = account.holdings.find_or_initialize_by(security: security, date: date, currency: currency)
      holding.assign_attributes(attributes)

      begin
        Holding.transaction(requires_new: true) { holding.save! }
      rescue ActiveRecord::RecordNotUnique
        existing = account.holdings.find_by!(security: security, date: date, currency: currency)
        existing.update!(attributes)
      end
    end

    def security_kind_for(value)
      kind = value.to_s
      Security::KINDS.include?(kind) ? kind : Security::KINDS.first
    end
end
