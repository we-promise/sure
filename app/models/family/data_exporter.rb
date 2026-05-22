require "zip"
require "csv"

class Family::DataExporter
  EXPORT_VERSION = 2

  def initialize(family)
    @family = family
  end

  def generate_export
    # Create a StringIO to hold the zip data in memory
    zip_data = Zip::OutputStream.write_buffer do |zipfile|
      # Add export version marker for downstream tooling
      zipfile.put_next_entry("version.txt")
      zipfile.write generate_version_txt

      # Add accounts.csv
      zipfile.put_next_entry("accounts.csv")
      zipfile.write generate_accounts_csv

      # Add transactions.csv
      zipfile.put_next_entry("transactions.csv")
      zipfile.write generate_transactions_csv

      # Add trades.csv
      zipfile.put_next_entry("trades.csv")
      zipfile.write generate_trades_csv

      # Add categories.csv
      zipfile.put_next_entry("categories.csv")
      zipfile.write generate_categories_csv

      # Add rules.csv
      zipfile.put_next_entry("rules.csv")
      zipfile.write generate_rules_csv

      # Add attachment manifest metadata. Binary file payloads are not included.
      zipfile.put_next_entry("attachments.json")
      zipfile.write generate_attachments_manifest

      # Add all.ndjson
      zipfile.put_next_entry("all.ndjson")
      zipfile.write generate_ndjson
    end

    # Rewind and return the StringIO
    zip_data.rewind
    zip_data
  end

  private
    def generate_version_txt
      <<~TEXT
        export_version: #{EXPORT_VERSION}
      TEXT
    end

    def generate_accounts_csv
      CSV.generate do |csv|
        csv << [ "id", "name", "type", "subtype", "balance", "currency", "created_at" ]

        # Only export accounts belonging to this family
        @family.accounts.includes(:accountable).find_each do |account|
          csv << [
            account.id,
            account.name,
            account.accountable_type,
            account.subtype,
            account.balance.to_s,
            account.currency,
            account.created_at.iso8601
          ]
        end
      end
    end

    def generate_transactions_csv
      CSV.generate do |csv|
        csv << [ "date", "account_name", "amount", "name", "category", "tags", "notes", "currency" ]

        # Only export transactions from accounts belonging to this family
        # Exclude split parents (export children instead)
        exportable_transactions
          .includes(:category, :tags, entry: :account)
          .find_each do |transaction|
            csv << [
              transaction.entry.date&.iso8601,
              transaction.entry.account.name,
              transaction.entry.amount.to_s,
              transaction.entry.name,
              transaction.category&.name,
              transaction.tags.map { |tag| escape_legacy_tag_name(tag.name) }.join(","),
              transaction.entry.notes,
              transaction.entry.currency
            ]
          end
      end
    end

    def escape_legacy_tag_name(name)
      name.to_s.gsub(/[\\,|]/) { |char| "\\#{char}" }
    end

    def generate_trades_csv
      CSV.generate do |csv|
        csv << [ "date", "account_name", "ticker", "quantity", "price", "amount", "currency" ]

        # Only export trades from accounts belonging to this family
        @family.trades
          .includes(:security, entry: :account)
          .find_each do |trade|
            csv << [
              trade.entry.date&.iso8601,
              trade.entry.account.name,
              trade.security.ticker,
              trade.qty.to_s,
              trade.price.to_s,
              trade.entry.amount.to_s,
              trade.currency
            ]
          end
      end
    end

    def generate_categories_csv
      CSV.generate do |csv|
        csv << [ "name", "color", "parent_category", "lucide_icon" ]

        # Only export categories belonging to this family
        @family.categories.includes(:parent).find_each do |category|
          csv << [
            category.name,
            category.color,
            category.parent&.name,
            category.lucide_icon
          ]
        end
      end
    end

    def generate_rules_csv
      CSV.generate do |csv|
        csv << [ "name", "resource_type", "active", "effective_date", "conditions", "actions" ]

        # Only export rules belonging to this family
        @family.rules.includes(conditions: :sub_conditions, actions: []).find_each do |rule|
          csv << [
            rule.name,
            rule.resource_type,
            rule.active,
            rule.effective_date&.iso8601,
            serialize_conditions_for_csv(rule.conditions),
            serialize_actions_for_csv(rule.actions)
          ]
        end
      end
    end

    def generate_attachments_manifest
      {
        version: 1,
        binary_included: false,
        attachments: attachment_manifest_items
      }.to_json
    end

    def attachment_manifest_items
      (transaction_attachment_manifest_items + family_document_attachment_manifest_items)
        .sort_by { |item| [ item[:record_type], item[:record_id].to_s, item[:filename].to_s, item[:id].to_s ] }
    end

    def transaction_attachment_manifest_items
      @family.transactions
        .with_attached_attachments
        .includes(:attachments_attachments, entry: :account)
        .flat_map do |transaction|
          transaction.attachments.map do |attachment|
            attachment_manifest_item(
              attachment,
              record_type: "Transaction",
              record_id: transaction.id,
              extra: {
                entry_id: transaction.entry.id,
                account_id: transaction.entry.account_id
              }
            )
          end
        end
    end

    def family_document_attachment_manifest_items
      @family.family_documents.with_attached_file.filter_map do |document|
        next unless document.file.attached?

        attachment_manifest_item(
          document.file.attachment,
          record_type: "FamilyDocument",
          record_id: document.id,
          extra: {
            status: document.status
          }
        )
      end
    end

    def attachment_manifest_item(attachment, record_type:, record_id:, extra: {})
      blob = attachment.blob
      {
        id: attachment.id,
        record_type: record_type,
        record_id: record_id,
        name: attachment.name,
        filename: blob.filename.to_s,
        content_type: blob.content_type,
        byte_size: blob.byte_size,
        checksum: blob.checksum,
        binary_included: false,
        created_at: attachment.created_at
      }.merge(extra)
    end

    def generate_ndjson
      lines = []

      # Export accounts with full accountable data
      @family.accounts.includes(:accountable).find_each do |account|
        lines << {
          type: "Account",
          data: account.as_json(
            include: {
              accountable: {}
            }
          )
        }.to_json
      end

      Balance.joins(:account)
        .where(accounts: { family_id: @family.id })
        .chronological
        .each do |balance|
        lines << {
          type: "Balance",
          data: {
            id: balance.id,
            account_id: balance.account_id,
            date: balance.date,
            balance: balance.balance,
            currency: balance.currency,
            cash_balance: balance.cash_balance,
            start_cash_balance: balance.start_cash_balance,
            start_non_cash_balance: balance.start_non_cash_balance,
            cash_inflows: balance.cash_inflows,
            cash_outflows: balance.cash_outflows,
            non_cash_inflows: balance.non_cash_inflows,
            non_cash_outflows: balance.non_cash_outflows,
            net_market_flows: balance.net_market_flows,
            cash_adjustments: balance.cash_adjustments,
            non_cash_adjustments: balance.non_cash_adjustments,
            flows_factor: balance.flows_factor,
            start_balance: balance.start_balance,
            end_cash_balance: balance.end_cash_balance,
            end_non_cash_balance: balance.end_non_cash_balance,
            end_balance: balance.end_balance,
            created_at: balance.created_at,
            updated_at: balance.updated_at
          }
        }.to_json
      end

      # Export categories
      @family.categories.find_each do |category|
        lines << {
          type: "Category",
          data: category.as_json
        }.to_json
      end

      # Export tags
      @family.tags.find_each do |tag|
        lines << {
          type: "Tag",
          data: tag.as_json
        }.to_json
      end

      # Export merchants (only family merchants)
      @family.merchants.find_each do |merchant|
        lines << {
          type: "Merchant",
          data: merchant.as_json
        }.to_json
      end

      # Export recurring transactions after accounts and merchants so import can remap dependencies.
      @family.recurring_transactions.includes(:account, :merchant).find_each do |recurring_transaction|
        lines << {
          type: "RecurringTransaction",
          data: serialize_recurring_transaction_for_export(recurring_transaction)
        }.to_json
      end

      # Export transactions with full data (exclude split parents, export children instead)
      exportable_transactions.includes(:category, :merchant, :tags, entry: :account).find_each do |transaction|
        lines << {
          type: "Transaction",
          data: {
            id: transaction.id,
            entry_id: transaction.entry.id,
            account_id: transaction.entry.account_id,
            date: transaction.entry.date,
            amount: transaction.entry.amount,
            currency: transaction.entry.currency,
            name: transaction.entry.name,
            notes: transaction.entry.notes,
            excluded: transaction.entry.excluded,
            category_id: transaction.category_id,
            merchant_id: transaction.merchant_id,
            tag_ids: transaction.tag_ids,
            kind: transaction.kind,
            created_at: transaction.created_at,
            updated_at: transaction.updated_at
          }
        }.to_json
      end

      # Export transfer decisions after transactions so import can remap both sides.
      family_transfers.find_each do |transfer|
        lines << {
          type: "Transfer",
          data: {
            id: transfer.id,
            inflow_transaction_id: transfer.inflow_transaction_id,
            outflow_transaction_id: transfer.outflow_transaction_id,
            status: transfer.status,
            notes: transfer.notes,
            created_at: transfer.created_at,
            updated_at: transfer.updated_at
          }
        }.to_json
      end

      family_rejected_transfers.find_each do |rejected_transfer|
        lines << {
          type: "RejectedTransfer",
          data: {
            id: rejected_transfer.id,
            inflow_transaction_id: rejected_transfer.inflow_transaction_id,
            outflow_transaction_id: rejected_transfer.outflow_transaction_id,
            created_at: rejected_transfer.created_at,
            updated_at: rejected_transfer.updated_at
          }
        }.to_json
      end

      # Export trades with full data
      @family.trades.includes(:security, entry: :account).find_each do |trade|
        lines << {
          type: "Trade",
          data: {
            id: trade.id,
            entry_id: trade.entry.id,
            account_id: trade.entry.account_id,
            security_id: trade.security_id,
            ticker: trade.security.ticker,
            security_name: trade.security.name,
            exchange_operating_mic: trade.security.exchange_operating_mic,
            date: trade.entry.date,
            qty: trade.qty,
            price: trade.price,
            amount: trade.entry.amount,
            currency: trade.currency,
            created_at: trade.created_at,
            updated_at: trade.updated_at
          }
        }.to_json
      end

      # Export holding snapshots for backup and portfolio verification.
      @family.holdings.includes(:account, :security).find_each do |holding|
        lines << {
          type: "Holding",
          data: {
            id: holding.id,
            account_id: holding.account_id,
            security_id: holding.security_id,
            ticker: holding.security.ticker,
            security_name: holding.security.name,
            exchange_operating_mic: holding.security.exchange_operating_mic,
            exchange_mic: holding.security.exchange_mic,
            exchange_acronym: holding.security.exchange_acronym,
            country_code: holding.security.country_code,
            kind: holding.security.kind,
            website_url: holding.security.website_url,
            date: holding.date,
            qty: holding.qty,
            price: holding.price,
            amount: holding.amount,
            currency: holding.currency,
            cost_basis: holding.cost_basis,
            cost_basis_source: holding.cost_basis_source,
            cost_basis_locked: holding.cost_basis_locked,
            security_locked: holding.security_locked
          }
        }.to_json
      end

      # Export valuations
      @family.entries.valuations.includes(:account, :entryable).find_each do |entry|
        lines << {
          type: "Valuation",
          data: {
            id: entry.entryable.id,
            entry_id: entry.id,
            account_id: entry.account_id,
            date: entry.date,
            amount: entry.amount,
            currency: entry.currency,
            name: entry.name,
            kind: entry.entryable.kind,
            created_at: entry.created_at,
            updated_at: entry.updated_at
          }
        }.to_json
      end

      # Export budgets
      @family.budgets.find_each do |budget|
        lines << {
          type: "Budget",
          data: budget.as_json
        }.to_json
      end

      # Export budget categories
      @family.budget_categories.includes(:budget, :category).find_each do |budget_category|
        lines << {
          type: "BudgetCategory",
          data: budget_category.as_json
        }.to_json
      end

      # Export rules with versioned schema
      @family.rules.includes(conditions: :sub_conditions, actions: []).find_each do |rule|
        lines << {
          type: "Rule",
          version: 1,
          data: serialize_rule_for_export(rule)
        }.to_json
      end

      lines.join("\n")
    end

    def exportable_transactions
      @family.transactions.merge(Entry.excluding_split_parents)
    end

    def family_transaction_ids
      @family_transaction_ids ||= exportable_transactions.select(:id)
    end

    def family_transfers
      Transfer.where(
        inflow_transaction_id: family_transaction_ids,
        outflow_transaction_id: family_transaction_ids
      )
    end

    def family_rejected_transfers
      RejectedTransfer.where(
        inflow_transaction_id: family_transaction_ids,
        outflow_transaction_id: family_transaction_ids
      )
    end

    def serialize_recurring_transaction_for_export(recurring_transaction)
      {
        id: recurring_transaction.id,
        account_id: recurring_transaction.account_id,
        merchant_id: recurring_transaction.merchant_id,
        amount: recurring_transaction.amount,
        currency: recurring_transaction.currency,
        expected_day_of_month: recurring_transaction.expected_day_of_month,
        last_occurrence_date: recurring_transaction.last_occurrence_date,
        next_expected_date: recurring_transaction.next_expected_date,
        status: recurring_transaction.status,
        occurrence_count: recurring_transaction.occurrence_count,
        name: recurring_transaction.name,
        manual: recurring_transaction.manual,
        expected_amount_min: recurring_transaction.expected_amount_min,
        expected_amount_max: recurring_transaction.expected_amount_max,
        expected_amount_avg: recurring_transaction.expected_amount_avg,
        created_at: recurring_transaction.created_at,
        updated_at: recurring_transaction.updated_at
      }
    end

    def serialize_rule_for_export(rule)
      {
        name: rule.name,
        resource_type: rule.resource_type,
        active: rule.active,
        effective_date: rule.effective_date&.iso8601,
        conditions: rule.conditions.where(parent_id: nil).map { |condition| serialize_condition(condition) },
        actions: rule.actions.map { |action| serialize_action(action) }
      }
    end

    def serialize_condition(condition)
      operand = resolve_condition_operand(condition)
      data = {
        condition_type: condition.condition_type,
        operator: condition.operator,
        value: operand[:value]
      }
      value_ref = operand[:value_ref]
      data[:value_ref] = value_ref if value_ref.present?

      if condition.compound? && condition.sub_conditions.any?
        data[:sub_conditions] = condition.sub_conditions.map { |sub| serialize_condition(sub) }
      end

      data
    end

    def serialize_action(action)
      operand = resolve_action_operand(action)
      data = {
        action_type: action.action_type,
        value: operand[:value]
      }
      value_ref = operand[:value_ref]
      data[:value_ref] = value_ref if value_ref.present?

      data
    end

    def resolve_condition_operand(condition)
      return rule_operand(condition.value) unless condition.value.present?

      # Map category UUIDs to names for portability
      if condition.condition_type == "transaction_category"
        return rule_operand(condition.value, type: "Category", relation: @family.categories)
      end

      # Map merchant UUIDs to names for portability
      if condition.condition_type == "transaction_merchant"
        return rule_operand(condition.value, type: "Merchant", relation: @family.merchants)
      end

      rule_operand(condition.value)
    end

    def resolve_action_operand(action)
      return rule_operand(action.value) unless action.value.present?

      # Map category UUIDs to names for portability
      if action.action_type == "set_transaction_category"
        return rule_operand(action.value, type: "Category", relation: @family.categories, fallback_to_name: true)
      end

      # Map merchant UUIDs to names for portability
      if action.action_type == "set_transaction_merchant"
        return rule_operand(action.value, type: "Merchant", relation: @family.merchants, fallback_to_name: true)
      end

      # Map tag UUIDs to names for portability
      if action.action_type == "set_transaction_tags"
        return rule_operand(action.value, type: "Tag", relation: @family.tags, fallback_to_name: true)
      end

      rule_operand(action.value)
    end

    def rule_operand(value, type: nil, relation: nil, fallback_to_name: false)
      record = relation && resolve_rule_operand_record(relation, value, fallback_to_name: fallback_to_name)

      {
        value: record&.name || value,
        value_ref: record ? rule_value_ref(type, record) : nil
      }
    end

    def resolve_rule_operand_record(relation, value, fallback_to_name:)
      return relation.find_by(id: value) if uuid_like?(value)

      relation.find_by(name: value) if fallback_to_name
    end

    def rule_value_ref(type, record)
      {
        type: type,
        id: record.id,
        name: record.name
      }
    end

    def uuid_like?(value)
      UuidFormat.valid?(value)
    end

    def serialize_conditions_for_csv(conditions)
      conditions.where(parent_id: nil).map { |c| serialize_condition(c) }.to_json
    end

    def serialize_actions_for_csv(actions)
      actions.map { |a| serialize_action(a) }.to_json
    end
end
