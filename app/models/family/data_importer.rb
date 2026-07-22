require "set"

class Family::DataImporter
  MissingReferenceError = Class.new(StandardError) do
    attr_reader :code, :details

    def initialize(record_type:, source_type:, source_id:)
      @code = "missing_source_reference"
      @details = {
        record_type: record_type,
        source_type: source_type,
        source_id: source_id
      }

      super("#{record_type} references missing #{source_type} source id #{source_id}")
    end
  end

  InvalidRecordError = Class.new(StandardError) do
    attr_reader :code, :details

    def initialize(record_type:, field:, value:)
      @code = "invalid_import_record"
      @details = {
        record_type: record_type,
        field: field,
        value: value
      }

      super("#{record_type} has invalid #{field}: #{value.inspect}")
    end
  end

  SUPPORTED_TYPES = %w[Account Balance Category Tag Merchant RecurringTransaction Transaction Transfer RejectedTransfer Trade Holding Valuation Budget BudgetCategory Rule].freeze
  ACCOUNTABLE_TYPE_CLASSES = {
    "Depository" => Depository, "Investment" => Investment, "Insurance" => Insurance, "Crypto" => Crypto,
    "Property" => Property, "Vehicle" => Vehicle, "OtherAsset" => OtherAsset,
    "CreditCard" => CreditCard, "Loan" => Loan, "OtherLiability" => OtherLiability
  }.freeze

  def self.accountable_class_for(type)
    ACCOUNTABLE_TYPE_CLASSES[type.to_s]
  end

  MAPPING_TYPES = {
    accounts: "Account",
    categories: "Category",
    tags: "Tag",
    merchants: "Merchant",
    recurring_transactions: "RecurringTransaction",
    transactions: "Transaction",
    budgets: "Budget",
    securities: "Security",
    rules: "Rule"
  }.freeze
  SUMMARY_KEYS = {
    "Account" => "accounts",
    "Balance" => "balances",
    "Category" => "categories",
    "Tag" => "tags",
    "Merchant" => "merchants",
    "RecurringTransaction" => "recurring_transactions",
    "Transaction" => "transactions",
    "Transfer" => "transfers",
    "RejectedTransfer" => "rejected_transfers",
    "Trade" => "trades",
    "Holding" => "holdings",
    "Valuation" => "valuations",
    "Budget" => "budgets",
    "BudgetCategory" => "budget_categories",
    "Rule" => "rules"
  }.freeze

  def initialize(family, ndjson_content, import_session: nil, import: nil)
    @family = family
    @ndjson_content = ndjson_content
    @import_session = import_session
    @import = import
    @strict_references = import_session.present?
    @id_mappings = {
      accounts: {},
      categories: {},
      tags: {},
      merchants: {},
      recurring_transactions: {},
      transactions: {},
      budgets: {},
      securities: {},
      rules: {}
    }
    @security_cache = {}
    @created_accounts = []
    @created_entries = []
    @summary = Hash.new { |hash, key| hash[key] = empty_summary_bucket }
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

    { accounts: @created_accounts, entries: @created_entries, summary: compact_summary }
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

    def empty_summary_bucket
      { "created" => 0, "updated" => 0, "skipped" => 0, "failed" => 0 }
    end

    def compact_summary
      @summary.select { |_entity_type, counts| counts.values.any?(&:positive?) }
    end

    def increment_summary(record_type, status)
      @summary[SUMMARY_KEYS.fetch(record_type)].tap do |counts|
        counts[status.to_s] = counts.fetch(status.to_s, 0) + 1
      end
    end

    def map_source!(mapping_key, source_id, target)
      return if source_id.blank? || target.blank?

      @id_mappings[mapping_key][source_id] = target.id
      return unless @import_session

      source_type = MAPPING_TYPES.fetch(mapping_key)
      mapping = @import_session.source_mappings.find_or_initialize_by(
        family: @family,
        source_type: source_type,
        source_id: source_id
      )
      mapping.target = target
      mapping.save!
    end

    def mapped_id(mapping_key, old_id, record_type:, required: true)
      if old_id.blank?
        missing_reference(record_type, mapping_key, "(blank)") if required
        return
      end

      return @id_mappings[mapping_key][old_id] if @id_mappings[mapping_key].key?(old_id)

      source_type = MAPPING_TYPES.fetch(mapping_key)
      mapping = @import_session&.source_mappings&.find_by(
        family: @family,
        source_type: source_type,
        source_id: old_id
      )

      if mapping
        @id_mappings[mapping_key][old_id] = mapping.target_id
        return mapping.target_id
      end

      if required && @strict_references
        raise MissingReferenceError.new(
          record_type: record_type,
          source_type: source_type,
          source_id: old_id
        )
      end

      nil
    end

    def mapped_record(mapping_key, old_id, scope, record_type:)
      target_id = mapped_id(mapping_key, old_id, record_type: record_type, required: false)
      return if target_id.blank?

      scope.find_by(id: target_id)
    end

    def missing_reference(record_type, mapping_key, old_id)
      if @strict_references
        increment_summary(record_type, :failed)
        raise MissingReferenceError.new(
          record_type: record_type,
          source_type: MAPPING_TYPES.fetch(mapping_key),
          source_id: old_id
        )
      end

      increment_summary(record_type, :skipped)
      nil
    end

    def require_source_id!(record_type, source_id)
      return if source_id.present? || !@strict_references

      increment_summary(record_type, :failed)
      raise MissingReferenceError.new(
        record_type: record_type,
        source_type: record_type,
        source_id: "(blank)"
      )
    end

    def invalid_record!(record_type, field, value)
      if @strict_references
        increment_summary(record_type, :failed)
        raise InvalidRecordError.new(record_type: record_type, field: field, value: value)
      end

      increment_summary(record_type, :skipped)
      nil
    end

    def session_entry_source
      return unless @import_session

      "sure_import_session:#{@import_session.id}"
    end

    def session_entry_external_id(record_type, source_id)
      return if @import_session.blank? || source_id.blank?

      "#{record_type}:#{source_id}"
    end

    def session_imported_entry(account, record_type, source_id)
      external_id = session_entry_external_id(record_type, source_id)
      return if external_id.blank?

      account.entries.find_by(source: session_entry_source, external_id: external_id)
    end

    def import_accounts(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]
        accountable_data = data["accountable"] || {}
        accountable_type = data["accountable_type"]

        require_source_id!("Account", old_id)

        accountable_class = self.class.accountable_class_for(accountable_type)

        unless accountable_class
          invalid_record!("Account", "accountable_type", accountable_type)
          next
        end

        account = mapped_record(:accounts, old_id, @family.accounts, record_type: "Account")
        created = account.blank?

        if account
          accountable = account.accountable
        else
          # Build accountable
          accountable = accountable_class.new
          accountable.subtype = accountable_data["subtype"] if accountable.respond_to?(:subtype=) && accountable_data["subtype"]

          # Copy any other accountable attributes
          safe_accountable_attrs = %w[subtype locked_attributes]
          safe_accountable_attrs += Insurance::POLICY_ATTRIBUTES.map(&:to_s) if accountable_type == "Insurance"
          safe_accountable_attrs.each do |attr|
            if accountable.respond_to?("#{attr}=") && accountable_data[attr].present?
              accountable.send("#{attr}=", accountable_data[attr])
            end
          end

          account = @family.accounts.build(accountable: accountable)
        end

        account.assign_attributes(
          name: data["name"],
          balance: data["balance"].to_d,
          cash_balance: data["cash_balance"]&.to_d || data["balance"].to_d,
          currency: data["currency"] || @family.currency,
          subtype: data["subtype"].presence || accountable_data["subtype"],
          institution_name: data["institution_name"],
          institution_domain: data["institution_domain"],
          notes: data["notes"],
          status: importable_account_status(data["status"])
        )

        account.save!

        # Set opening balance if we have a historical balance and the import
        # does not provide either an explicit opening-anchor valuation or an
        # authoritative balance-history stream for this account.
        if created && data["balance"].present? && !skip_opening_balance_import?(old_id, data)
          manager = Account::OpeningBalanceManager.new(account)
          result = manager.set_opening_balance(
            balance: data["balance"].to_d,
            date: opening_balance_date_for(old_id, data)
          )
          log_failed_opening_balance_import(account, old_id, result) unless result.success?
        end

        map_source!(:accounts, old_id, account)
        @created_accounts << account if created
        increment_summary("Account", created ? :created : :updated)
      end
    end

    def importable_account_status(status)
      status.to_s.in?(%w[active disabled draft]) ? status.to_s : "active"
    end

    def import_balances(records)
      records.each do |record|
        data = record["data"] || {}
        new_account_id = mapped_id(:accounts, data["account_id"], record_type: "Balance")
        balance_date = parse_import_date(data["date"])
        next if new_account_id.blank?

        if balance_date.blank? || data["balance"].blank?
          increment_summary("Balance", :skipped)
          next
        end

        account = @family.accounts.find(new_account_id)
        currency = data["currency"].presence || account.currency
        balance = account.balances.find_or_initialize_by(date: balance_date, currency: currency)
        created = balance.new_record?

        balance.assign_attributes(imported_balance_attributes(data))
        balance.save!
        increment_summary("Balance", created ? :created : :updated)
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

        require_source_id!("Category", old_id)

        # Store parent relationship for second pass
        parent_mappings[old_id] = parent_id if parent_id.present?

        category = mapped_record(:categories, old_id, @family.categories, record_type: "Category")
        created = category.blank?
        category ||= @family.categories.build

        category.assign_attributes(
          name: data["name"],
          color: data["color"] || Category::UNCATEGORIZED_COLOR,
          classification_unused: data["classification_unused"] || data["classification"] || "expense",
          lucide_icon: data["lucide_icon"] || "shapes"
        )
        category.save!
        map_source!(:categories, old_id, category)
        increment_summary("Category", created ? :created : :updated)
      end

      # Second pass: establish parent relationships
      parent_mappings.each do |old_id, old_parent_id|
        new_id = mapped_id(:categories, old_id, record_type: "Category")
        new_parent_id = mapped_id(:categories, old_parent_id, record_type: "Category")

        next unless new_id && new_parent_id

        category = @family.categories.find(new_id)
        category.update!(parent_id: new_parent_id)
      end
    end

    def import_tags(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

        require_source_id!("Tag", old_id)

        tag = mapped_record(:tags, old_id, @family.tags, record_type: "Tag")
        created = tag.blank?
        tag ||= @family.tags.build
        color = data["color"] || tag.color
        # Keep replayed session imports deterministic when the source omits a color.
        color ||= Tag::COLORS.first if created

        tag.assign_attributes(
          name: data["name"],
          color: color
        )
        tag.save!
        map_source!(:tags, old_id, tag)
        increment_summary("Tag", created ? :created : :updated)
      end
    end

    def import_merchants(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

        require_source_id!("Merchant", old_id)

        merchant = mapped_record(:merchants, old_id, @family.merchants, record_type: "Merchant")
        created = merchant.blank?
        merchant ||= @family.merchants.build

        merchant.assign_attributes(
          name: data["name"],
          color: data["color"],
          logo_url: data["logo_url"]
        )
        merchant.save!
        map_source!(:merchants, old_id, merchant)
        increment_summary("Merchant", created ? :created : :updated)
      end
    end

    def import_recurring_transactions(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

        require_source_id!("RecurringTransaction", old_id)

        recurring_transaction = mapped_record(
          :recurring_transactions,
          old_id,
          @family.recurring_transactions,
          record_type: "RecurringTransaction"
        )
        created = recurring_transaction.blank?

        new_account_id = remap_optional_id(:accounts, data["account_id"], record_type: "RecurringTransaction")
        next if data["account_id"].present? && new_account_id.blank?

        new_merchant_id = remap_optional_id(:merchants, data["merchant_id"], record_type: "RecurringTransaction")
        next if data["merchant_id"].present? && new_merchant_id.blank?

        expected_day_of_month = recurring_expected_day_for(data["expected_day_of_month"])
        next unless expected_day_of_month
        last_occurrence_date = parse_import_date(data["last_occurrence_date"])
        next_expected_date = parse_import_date(data["next_expected_date"])
        next unless last_occurrence_date && next_expected_date

        recurring_transaction ||= @family.recurring_transactions.build
        recurring_transaction.assign_attributes(
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
        map_source!(:recurring_transactions, old_id, recurring_transaction)
        increment_summary("RecurringTransaction", created ? :created : :updated)
      end
    end

    def remap_optional_id(mapping_key, old_id, record_type:)
      return if old_id.blank?

      mapped_id(mapping_key, old_id, record_type: record_type)
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

        require_source_id!("Transaction", old_id)

        # Map account ID
        new_account_id = mapped_id(:accounts, data["account_id"], record_type: "Transaction")
        next unless new_account_id

        account = @family.accounts.find(new_account_id)

        # Map category ID (optional)
        new_category_id = nil
        if data["category_id"].present?
          new_category_id = mapped_id(:categories, data["category_id"], record_type: "Transaction")
        end

        # Map merchant ID (optional)
        new_merchant_id = nil
        if data["merchant_id"].present?
          new_merchant_id = mapped_id(:merchants, data["merchant_id"], record_type: "Transaction")
        end

        # Map tag IDs (optional)
        new_tag_ids = mapped_tag_ids(data["tag_ids"], record_type: "Transaction")

        entry = session_imported_entry(account, "Transaction", old_id)
        transaction = entry&.entryable if entry&.entryable.is_a?(Transaction)
        created = transaction.blank?

        transaction ||= Transaction.new
        transaction.assign_attributes(
          category_id: new_category_id,
          merchant_id: new_merchant_id,
          kind: data["kind"] || "standard"
        )

        entry ||= Entry.new(entryable: transaction)
        entry.assign_attributes(
          account: account,
          date: Date.parse(data["date"].to_s),
          amount: data["amount"].to_d,
          name: data["name"] || "Imported transaction",
          currency: data["currency"] || account.currency,
          notes: data["notes"],
          excluded: data["excluded"] || false
        )
        if @import_session
          entry.external_id = session_entry_external_id("Transaction", old_id)
          entry.source = session_entry_source
        end

        entry.save!

        map_source!(:transactions, old_id, transaction)
        split_rows = importable_split_rows(data)

        if split_rows.any?
          @created_entries << entry if created
          import_split_lines!(entry, split_rows, fallback_tag_ids: new_tag_ids)
        else
          transaction.taggings.destroy_all unless created
          new_tag_ids.each do |tag_id|
            transaction.taggings.create!(tag_id: tag_id)
          end

          @created_entries << entry if created
        end

        increment_summary("Transaction", created ? :created : :updated)
      end
    end

    def mapped_tag_ids(old_tag_ids, record_type:)
      Array(old_tag_ids).map do |old_tag_id|
        mapped_id(:tags, old_tag_id, record_type: record_type)
      end.compact
    end

    def importable_split_rows(data)
      rows = data["split_lines"].presence || data["splitLines"].presence || data["splits"].presence
      Array(rows).filter_map do |row|
        next unless row.is_a?(Hash)

        amount = row["amount"] || row["amount_money"] || row["amount_decimal"]
        next if amount.blank?

        category_id = remap_optional_id(:categories, row["category_id"], record_type: "Transaction")
        merchant_id = remap_optional_id(:merchants, row["merchant_id"], record_type: "Transaction")

        {
          old_id: row["id"],
          name: row["name"].presence || row["memo"].presence || row["description"].presence || "Imported split",
          amount: amount.to_d,
          category_id: category_id,
          merchant_id: merchant_id,
          merchant_id_provided: row.key?("merchant_id"),
          notes: row["notes"],
          excluded: boolean_import_value(row, "excluded", default: false),
          tag_ids: mapped_tag_ids(row["tag_ids"], record_type: "Transaction"),
          tag_ids_provided: row.key?("tag_ids"),
          kind: row["kind"]
        }
      end
    end

    def import_split_lines!(entry, split_rows, fallback_tag_ids:)
      children = entry.split!(
        split_rows.map do |row|
          {
            name: row[:name],
            amount: row[:amount],
            category_id: row[:category_id],
            excluded: row[:excluded]
          }
        end
      )

      children.zip(split_rows).each do |child_entry, row|
        transaction = child_entry.entryable
        transaction.update!(
          merchant_id: row[:merchant_id_provided] ? row[:merchant_id] : transaction.merchant_id,
          kind: row[:kind].presence || transaction.kind
        )
        child_entry.update!(notes: row[:notes]) if row[:notes].present?

        tag_ids = row[:tag_ids_provided] ? row[:tag_ids] : fallback_tag_ids
        tag_ids.each do |tag_id|
          transaction.taggings.create!(tag_id: tag_id)
        end

        map_source!(:transactions, row[:old_id], transaction) if row[:old_id].present?
        @created_entries << child_entry
      end
    end

    def import_transfers(records)
      records.each do |record|
        data = record["data"]
        inflow_transaction_id = mapped_id(:transactions, data["inflow_transaction_id"], record_type: "Transfer")
        outflow_transaction_id = mapped_id(:transactions, data["outflow_transaction_id"], record_type: "Transfer")
        next unless inflow_transaction_id && outflow_transaction_id

        transfer = Transfer.find_or_create_by!(
          inflow_transaction_id: inflow_transaction_id,
          outflow_transaction_id: outflow_transaction_id
        ) do |transfer|
          transfer.status = transfer_status_for(data["status"])
          transfer.notes = data["notes"]
        end
        apply_transfer_transaction_kinds!(transfer)
        increment_summary("Transfer", transfer.previously_new_record? ? :created : :updated)
      end
    end

    def apply_transfer_transaction_kinds!(transfer)
      destination_account = transfer.inflow_transaction.entry.account
      outflow_kind = imported_transfer_outflow_kind(transfer)
      outflow_attrs = { kind: outflow_kind }
      if outflow_kind == "investment_contribution" && transfer.outflow_transaction.category_id.blank?
        outflow_attrs[:category] = destination_account.family.investment_contributions_category
      end

      transfer.outflow_transaction.update!(outflow_attrs)
      transfer.inflow_transaction.update!(kind: "funds_movement")
    end

    def imported_transfer_outflow_kind(transfer)
      source_account = transfer.outflow_transaction.entry.account
      destination_account = transfer.inflow_transaction.entry.account
      return "loan_payment" if destination_account.loan?
      return "cc_payment" if destination_account.liability?
      return "investment_contribution" if investment_account?(destination_account) && !investment_account?(source_account)

      "funds_movement"
    end

    def investment_account?(account)
      account.investment? || account.crypto?
    end

    def import_rejected_transfers(records)
      records.each do |record|
        data = record["data"]
        inflow_transaction_id = mapped_id(:transactions, data["inflow_transaction_id"], record_type: "RejectedTransfer")
        outflow_transaction_id = mapped_id(:transactions, data["outflow_transaction_id"], record_type: "RejectedTransfer")
        next unless inflow_transaction_id && outflow_transaction_id

        rejected_transfer = RejectedTransfer.find_or_create_by!(
          inflow_transaction_id: inflow_transaction_id,
          outflow_transaction_id: outflow_transaction_id
        )
        increment_summary("RejectedTransfer", rejected_transfer.previously_new_record? ? :created : :updated)
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
        old_id = data["id"]

        require_source_id!("Trade", old_id)

        # Map account ID
        new_account_id = mapped_id(:accounts, data["account_id"], record_type: "Trade")
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

        entry = session_imported_entry(account, "Trade", old_id)
        trade = entry&.entryable if entry&.entryable.is_a?(Trade)
        created = trade.blank?

        trade ||= Trade.new
        trade.assign_attributes(
          security: security,
          qty: data["qty"].to_d,
          price: data["price"].to_d,
          currency: data["currency"] || account.currency
        )

        entry ||= Entry.new(entryable: trade)
        entry.assign_attributes(
          account: account,
          date: Date.parse(data["date"].to_s),
          amount: data["amount"].to_d,
          name: "#{data["qty"].to_d >= 0 ? 'Buy' : 'Sell'} #{ticker}",
          currency: data["currency"] || account.currency
        )
        if @import_session
          entry.external_id = session_entry_external_id("Trade", old_id)
          entry.source = session_entry_source
        end

        entry.save!
        @created_entries << entry if created
        increment_summary("Trade", created ? :created : :updated)
      end
    end

    def import_holdings(records)
      account_ids = records.filter_map do |record|
        mapped_id(:accounts, record.dig("data", "account_id"), record_type: "Holding", required: false)
      end
      accounts_by_id = @family.accounts.where(id: account_ids).index_by(&:id)

      records.each do |record|
        data = record["data"]

        new_account_id = mapped_id(:accounts, data["account_id"], record_type: "Holding")
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

        created = upsert_imported_holding!(account, security, holding_date, holding_currency, holding_attributes)
        increment_summary("Holding", created ? :created : :updated)
      end
    end

    def import_valuations(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

        require_source_id!("Valuation", old_id)

        # Map account ID
        new_account_id = mapped_id(:accounts, data["account_id"], record_type: "Valuation")
        next unless new_account_id

        account = @family.accounts.find(new_account_id)

        entry = session_imported_entry(account, "Valuation", old_id)
        valuation = entry&.entryable if entry&.entryable.is_a?(Valuation)
        created = valuation.blank?
        valuation ||= Valuation.new
        valuation.kind = valuation_kind_for(data["kind"])

        entry ||= Entry.new(entryable: valuation)
        entry.assign_attributes(
          account: account,
          date: Date.parse(data["date"].to_s),
          amount: data["amount"].to_d,
          name: data["name"] || "Valuation",
          currency: data["currency"] || account.currency
        )
        if @import_session
          entry.external_id = session_entry_external_id("Valuation", old_id)
          entry.source = session_entry_source
        end

        entry.save!
        @created_entries << entry if created
        increment_summary("Valuation", created ? :created : :updated)
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

    def skip_opening_balance_import?(old_id, data)
      @imported_opening_anchor_account_ids.include?(old_id) ||
        truthy?(data["skip_opening_balance_import"]) ||
        truthy?(data["authoritative_balance_history"])
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

        require_source_id!("Budget", old_id)

        budget = mapped_record(:budgets, old_id, @family.budgets, record_type: "Budget")
        created = budget.blank?
        budget ||= @family.budgets.build

        budget.assign_attributes(
          start_date: Date.parse(data["start_date"].to_s),
          end_date: Date.parse(data["end_date"].to_s),
          budgeted_spending: data["budgeted_spending"]&.to_d,
          expected_income: data["expected_income"]&.to_d,
          currency: data["currency"] || @family.currency
        )

        budget.save!
        map_source!(:budgets, old_id, budget)
        increment_summary("Budget", created ? :created : :updated)
      end
    end

    def import_budget_categories(records)
      records.each do |record|
        data = record["data"]

        # Map budget ID
        new_budget_id = mapped_id(:budgets, data["budget_id"], record_type: "BudgetCategory")
        next unless new_budget_id

        # Map category ID
        new_category_id = mapped_id(:categories, data["category_id"], record_type: "BudgetCategory")
        next unless new_category_id

        budget = @family.budgets.find(new_budget_id)

        budget_category = budget.budget_categories.find_or_initialize_by(category_id: new_category_id)
        created = budget_category.new_record?
        budget_category.assign_attributes(
          category_id: new_category_id,
          budgeted_spending: data["budgeted_spending"].to_d,
          currency: data["currency"] || budget.currency
        )

        budget_category.save!
        increment_summary("BudgetCategory", created ? :created : :updated)
      end
    end

    def import_rules(records)
      records.each do |record|
        data = record["data"]
        old_id = data["id"]

        require_source_id!("Rule", old_id)

        rule = mapped_record(:rules, old_id, @family.rules, record_type: "Rule")
        created = rule.blank?
        rule ||= @family.rules.build

        rule.assign_attributes(
          name: data["name"],
          resource_type: data["resource_type"] || "transaction",
          active: data["active"] || false,
          effective_date: data["effective_date"].present? ? Date.parse(data["effective_date"].to_s) : nil
        )

        rule.conditions.destroy_all unless created
        rule.actions.destroy_all unless created

        # Build conditions
        (data["conditions"] || []).each do |condition_data|
          build_rule_condition(rule, condition_data)
        end

        # Build actions
        (data["actions"] || []).each do |action_data|
          build_rule_action(rule, action_data)
        end

        rule.save!
        map_source!(:rules, old_id, rule)
        increment_summary("Rule", created ? :created : :updated)
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

      mapped_security_id = mapped_id(:securities, old_security_id, record_type: "Security", required: false)
      if old_security_id.present? && mapped_security_id
        security = Security.find(mapped_security_id)
        apply_security_metadata(security, normalized_ticker, attributes)
        @security_cache[cache_key] = security
        return security
      end

      security = find_security_by_identity(normalized_ticker, exchange_operating_mic)
      apply_security_metadata(security, normalized_ticker, attributes)

      @security_cache[cache_key] = security
      map_source!(:securities, old_security_id, security) if old_security_id.present?
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
      created = holding.new_record?
      holding.assign_attributes(attributes)

      begin
        Holding.transaction(requires_new: true) { holding.save! }
      rescue ActiveRecord::RecordNotUnique
        existing = account.holdings.find_by!(security: security, date: date, currency: currency)
        existing.update!(attributes)
        created = false
      end

      created
    end

    def security_kind_for(value)
      kind = value.to_s
      Security::KINDS.include?(kind) ? kind : Security::KINDS.first
    end
end
