# frozen_string_literal: true

require "set"

class SureImport::Preflight
  Result = Struct.new(:errors, :warnings, :stats, keyword_init: true) do
    def valid? = errors.empty?
    def error_messages = errors.map { |error| error[:message] }
    def error_message = valid? ? "" : ([ "Sure import preflight failed:" ] + error_messages).join("\n")
    def payload = { valid: valid?, stats: stats, errors: errors, warnings: warnings }
  end

  REQUIRED_FIELDS = {
    "Account" => %w[id name balance accountable_type],
    "Balance" => %w[account_id date balance],
    "Category" => %w[id name],
    "Tag" => %w[id name],
    "Merchant" => %w[id name],
    "RecurringTransaction" => %w[id amount expected_day_of_month last_occurrence_date next_expected_date],
    "Transaction" => %w[id account_id date amount],
    "Transfer" => %w[inflow_transaction_id outflow_transaction_id],
    "RejectedTransfer" => %w[inflow_transaction_id outflow_transaction_id],
    "Trade" => %w[account_id date amount qty price ticker],
    "Holding" => %w[account_id date amount qty price ticker],
    "Valuation" => %w[account_id date amount],
    "Budget" => %w[id start_date end_date],
    "BudgetCategory" => %w[budget_id category_id],
    "Rule" => %w[name]
  }.freeze

  TAXONOMY_TYPES = { "Category" => :categories, "Tag" => :tags, "Merchant" => :merchants }.freeze

  SOURCE_ID_TYPES = TAXONOMY_TYPES.merge(
    "Account" => :accounts,
    "RecurringTransaction" => :recurring_transactions,
    "Transaction" => :transactions,
    "Budget" => :budgets
  ).freeze

  REFERENCE_FIELDS = {
    "Balance" => { accounts: %w[account_id] },
    "Category" => { categories: %w[parent_id] },
    "RecurringTransaction" => { accounts: %w[account_id], merchants: %w[merchant_id] },
    "Transaction" => { accounts: %w[account_id], categories: %w[category_id], merchants: %w[merchant_id] },
    "Transfer" => { transactions: %w[inflow_transaction_id outflow_transaction_id] },
    "RejectedTransfer" => { transactions: %w[inflow_transaction_id outflow_transaction_id] },
    "Trade" => { accounts: %w[account_id] },
    "Holding" => { accounts: %w[account_id] },
    "Valuation" => { accounts: %w[account_id] },
    "BudgetCategory" => { budgets: %w[budget_id], categories: %w[category_id] }
  }.freeze

  def initialize(family:, content:)
    @family = family
    @content = content.to_s
    @errors = []
    @warnings = []
    @line_counts = Hash.new(0)
    @records = Hash.new { |hash, key| hash[key] = [] }
    @source_ids = Hash.new { |hash, key| hash[key] = Set.new }
    @source_id_locations = Hash.new { |hash, key| hash[key] = Hash.new { |ids, id| ids[id] = [] } }
    @rows_count = 0
    @valid_rows_count = 0
  end

  def call
    parse_records
    validate_taxonomy_collisions
    validate_duplicate_taxonomy_names
    validate_duplicate_source_ids
    validate_required_fields
    validate_accountables
    validate_split_lines
    validate_references
    validate_duplicate_valuations
    Result.new(
      errors: @errors,
      warnings: @warnings,
      stats: {
        rows_count: @rows_count,
        valid_rows_count: @valid_rows_count,
        invalid_rows_count: @rows_count - @valid_rows_count,
        entity_counts: SureImport.dry_run_totals_from_line_type_counts(@line_counts),
        record_type_counts: @line_counts
      }
    )
  end

  private
    attr_reader :family

    def parse_records
      @content.each_line.with_index(1) do |line, line_number|
        next if line.strip.blank?
        @rows_count += 1
        record = JSON.parse(line)
        unless record.is_a?(Hash)
          add_error(:invalid_ndjson_record, "Line #{line_number} must be a JSON object.")
          next
        end

        type = record["type"]
        data = record["data"]
        if type.blank? || !record.key?("data")
          add_error(:invalid_ndjson_record, "Line #{line_number} must include type and data.")
          next
        end

        @line_counts[type] += 1
        unless Family::DataImporter::SUPPORTED_TYPES.include?(type)
          add_error(:unsupported_record_type, "Line #{line_number} has unsupported record type #{type}.")
          next
        end

        unless data.is_a?(Hash)
          add_error(:invalid_ndjson_record, "Line #{line_number} data must be a JSON object.")
          next
        end

        @valid_rows_count += 1
        @records[type] << { line_number: line_number, data: data }
        mapping_key = SOURCE_ID_TYPES[type]
        track_source_id(mapping_key, data["id"], "Line #{line_number} #{type}") if mapping_key && data["id"].present?
        add_split_line_source_ids(data, line_number) if type == "Transaction"
      rescue JSON::ParserError => e
        add_error(:invalid_json, "Line #{line_number} is not valid JSON: #{e.message}")
      end

      add_error(:no_data_rows, "No data rows were found.") if @rows_count.zero?
    end

    def track_source_id(mapping_key, id, location)
      id = id.to_s
      @source_ids[mapping_key].add(id)
      @source_id_locations[mapping_key][id] << location
    end

    def add_split_line_source_ids(data, line_number)
      split_lines = split_lines_value(data)
      return unless split_lines.is_a?(Array)
      split_lines.each_with_index do |split_line, index|
        next unless split_line.is_a?(Hash) && split_line["id"].present?
        track_source_id(:transactions, split_line["id"], "Line #{line_number} Transaction split line #{index + 1}")
      end
    end

    def validate_taxonomy_collisions
      TAXONOMY_TYPES.each do |type, association|
        existing_names = family.public_send(association).pluck(:name).to_set
        @records[type].each do |record|
          name = record[:data]["name"].to_s
          next if name.blank? || !existing_names.include?(name)
          add_error(
            :existing_taxonomy_collision,
            "Line #{record[:line_number]} #{type} name #{name.inspect} already exists in this family."
          )
        end
      end
    end

    def validate_duplicate_taxonomy_names
      TAXONOMY_TYPES.each_key do |type|
        grouped = @records[type].group_by { |record| record[:data]["name"].to_s }
        grouped.each do |name, records|
          next if name.blank? || records.one?
          lines = records.map { |record| record[:line_number] }.join(", ")
          add_error(:duplicate_taxonomy_name, "#{type} name #{name.inspect} appears more than once in the NDJSON on lines #{lines}.")
        end
      end
    end

    def validate_duplicate_source_ids
      @source_id_locations.each do |mapping_key, ids|
        ids.each do |id, locations|
          next if locations.one?
          add_error(
            :duplicate_source_id,
            "#{mapping_key.to_s.singularize.tr('_', ' ')} source id #{id.inspect} appears more than once (#{locations.join(', ')})."
          )
        end
      end
    end

    def validate_required_fields
      @records.each do |type, records|
        required_fields = REQUIRED_FIELDS.fetch(type, [])
        records.each do |record|
          missing = required_fields.select { |field| blank_required_value?(record[:data][field]) }
          next if missing.empty?
          add_error(:missing_required_fields, "Line #{record[:line_number]} #{type} is missing required field(s): #{missing.join(', ')}.")
        end
      end
    end

    def validate_accountables
      @records["Account"].each do |record|
        data = record[:data]
        accountable_type = data["accountable_type"].to_s
        accountable_class = Family::DataImporter.accountable_class_for(accountable_type)
        unless accountable_class
          add_error(:invalid_accountable_type, "Line #{record[:line_number]} Account has invalid accountable_type #{accountable_type.inspect}.")
          next
        end

        subtype = data.dig("accountable", "subtype").presence || data["subtype"].presence
        next if subtype.blank?
        subtype_map = accountable_class.const_defined?(:SUBTYPES) ? accountable_class::SUBTYPES : {}
        next if subtype_map.blank? || subtype_map.key?(subtype)
        add_error(:invalid_accountable_subtype, "Line #{record[:line_number]} Account has invalid #{accountable_type} subtype #{subtype.inspect}.")
      end
    end

    def validate_split_lines
      @records["Transaction"].each do |record|
        split_lines = split_lines_value(record[:data])
        next if split_lines.blank?
        unless split_lines.is_a?(Array)
          add_error(:invalid_split_lines, "Line #{record[:line_number]} Transaction split_lines must be an array.")
          next
        end

        complete_amounts = true
        split_lines.each_with_index do |split_line, index|
          unless split_line.is_a?(Hash)
            add_error(:invalid_split_line, "Line #{record[:line_number]} Transaction split line #{index + 1} must be a JSON object.")
            complete_amounts = false
            next
          end

          next unless blank_required_value?(split_line_amount(split_line))
          add_error(:missing_required_fields, "Line #{record[:line_number]} Transaction split line #{index + 1} is missing required field(s): amount.")
          complete_amounts = false
        end

        validate_split_line_total(record, split_lines) if complete_amounts && record[:data]["amount"].present?
      end
    end

    def validate_split_line_total(record, split_lines)
      expected_amount = record[:data]["amount"].to_d
      split_total = split_lines.sum { |split_line| split_line_amount(split_line).to_d }
      return if split_total == expected_amount
      add_error(
        :split_amount_mismatch,
        "Line #{record[:line_number]} Transaction split line amounts must sum to transaction amount #{expected_amount.to_s('F')} but sum to #{split_total.to_s('F')}."
      )
    end

    def validate_references
      @records.each do |type, records|
        reference_fields = REFERENCE_FIELDS.fetch(type, {})
        records.each do |record|
          reference_fields.each do |mapping_key, fields|
            fields.each do |field|
              validate_reference(record, type, mapping_key, field, record[:data][field])
            end
          end

          validate_tag_references(record, type)
          validate_split_line_references(record) if type == "Transaction"
        end
      end
    end

    def validate_reference(record, type, mapping_key, field, value)
      return if value.blank?
      return if @source_ids[mapping_key].include?(value.to_s)
      add_error(:missing_reference, "Line #{record[:line_number]} #{type} references missing #{field} #{value.inspect}.")
    end

    def validate_tag_references(record, type)
      Array(record[:data]["tag_ids"]).each do |tag_id|
        validate_reference(record, type, :tags, "tag_ids", tag_id)
      end
    end

    def validate_split_line_references(record)
      split_lines = split_lines_value(record[:data])
      return unless split_lines.is_a?(Array)
      Array(split_lines).each do |split_line|
        next unless split_line.is_a?(Hash)
        validate_reference(record, "Transaction split line", :categories, "category_id", split_line["category_id"])
        validate_reference(record, "Transaction split line", :merchants, "merchant_id", split_line["merchant_id"])
        Array(split_line["tag_ids"]).each do |tag_id|
          validate_reference(record, "Transaction split line", :tags, "tag_ids", tag_id)
        end
      end
    end

    def split_lines_value(data) = data["split_lines"].presence || data["splitLines"].presence || data["splits"].presence

    def split_line_amount(split_line) = split_line["amount"] || split_line["amount_money"] || split_line["amount_decimal"]

    def validate_duplicate_valuations
      seen = {}
      @records["Valuation"].each do |record|
        account_id = record[:data]["account_id"]
        date = record[:data]["date"]
        next if account_id.blank? || date.blank?
        key = [ account_id.to_s, date.to_s ]
        if seen.key?(key)
          add_error(:duplicate_valuation, "Line #{record[:line_number]} duplicates valuation for account #{account_id.inspect} on #{date}; first seen on line #{seen[key]}.")
        else
          seen[key] = record[:line_number]
        end
      end
    end

    def blank_required_value?(value) = value.blank?

    def add_error(code, message) = @errors << { code: code.to_s, message: message }
end
