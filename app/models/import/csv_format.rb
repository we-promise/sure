# frozen_string_literal: true

class Import::CsvFormat
  TRANSACTION_TYPES = {
    "generic" => "TransactionImport",
    "mint" => "MintImport",
    "actual" => "ActualImport",
    "ynab" => "YnabImport"
  }.freeze

  def self.options
    [ [ "auto", "auto" ], *TRANSACTION_TYPES.keys.map { |key| [ key, key ] } ]
  end

  def self.import_type(selection:, content:, col_sep: ",")
    return TRANSACTION_TYPES.fetch(selection) if TRANSACTION_TYPES.key?(selection)
    return "TransactionImport" unless selection == "auto"

    detect(content, col_sep: col_sep) || "TransactionImport"
  end

  def self.detect(content, col_sep: ",")
    headers = Import.parse_csv_str(content, col_sep: col_sep).headers
    normalized = Array(headers).compact.map { |header| normalize(header) }
    header_set = normalized.to_set

    return "MintImport" if mint_headers?(header_set)
    return "ActualImport" if actual_headers?(header_set)
    return "YnabImport" if ynab_headers?(header_set)
  rescue CSV::MalformedCSVError
    nil
  end

  def self.default_column_mappings(import_type)
    import_class = import_type.safe_constantize
    return {} unless import_class&.respond_to?(:default_column_mappings)

    import_class.default_column_mappings
  end

  def self.normalize(header)
    header.to_s.strip.downcase.gsub("*", "").gsub(/[\s-]+/, "_")
  end
  private_class_method :normalize

  def self.mint_headers?(headers)
    %w[date amount description].all? { |header| headers.include?(header) } &&
      (headers.include?("transaction_type") || headers.include?("labels"))
  end
  private_class_method :mint_headers?

  def self.actual_headers?(headers)
    %w[date payee amount].all? { |header| headers.include?(header) } &&
      headers.include?("split_amount")
  end
  private_class_method :actual_headers?

  def self.ynab_headers?(headers)
    (headers.include?("outflow") || headers.include?("inflow")) &&
      (headers.include?("category_group/category") || headers.include?("master_category") || headers.include?("sub_category"))
  end
  private_class_method :ynab_headers?
end
