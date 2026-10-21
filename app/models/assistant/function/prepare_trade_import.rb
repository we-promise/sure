# frozen_string_literal: true

# Prepares a broker trade CSV for import the way the manual import screens do,
# and stops before anything is imported.
#
# The steps are the manual flow's own: create the TradeImport as
# ImportsController#create does, store the CSV as Import::UploadsController
# does, set the column labels as Import::ConfigurationsController does, then
# generate_rows_from_csv and sync_mappings. So the rows this produces are the
# rows the manual mapping produces for the same choices -- the tool only picks
# the column labels. No entry, trade or security is written: the import stays
# pending until it is published.
class Assistant::Function::PrepareTradeImport < Assistant::Function
  # Header spellings brokers use, per column key. Matched case- and
  # punctuation-insensitively; an explicit column_mapping always wins.
  HEADER_SYNONYMS = {
    "date" => [ "date", "trade date", "transaction date", "execution date" ],
    "ticker" => [ "ticker", "symbol", "ticker symbol", "security symbol", "instrument" ],
    "qty" => [ "qty", "quantity", "shares", "units", "no of shares" ],
    "price" => [ "price", "unit price", "share price", "price per share", "execution price" ],
    "currency" => [ "currency", "ccy", "trade currency" ],
    "exchange_operating_mic" => [ "exchange operating mic", "mic", "exchange mic" ],
    "name" => [ "name", "description", "security name" ],
    "account" => [ "account", "account name" ]
  }.freeze
  MAX_INVALID_ROWS_REPORTED = 20
  SAMPLE_ROWS = 5

  class << self
    def name
      "prepare_trade_import"
    end

    def description
      <<~INSTRUCTIONS
        Prepares a CSV of investment trades (buys and sells) from a broker for import,
        and stops before anything is imported. Pass the CSV text as csv_content.

        It works out which column holds the date, ticker, quantity, price and, when
        present, currency, exchange MIC, name and account, detects the date format,
        and checks every row. The result lists the mapping it chose, the rows that
        will not import and why, and a sample of the parsed rows. Nothing is written
        to the user's accounts: the import is left pending for the user to review.

        Pass column_mapping to correct a column the detection got wrong, using the
        CSV's own header names. Positive quantities are buys and negative are sells
        unless signage_convention says otherwise. Ask which account to import into
        when the CSV has no account column.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "csv_content" ],
      properties: {
        csv_content: { type: "string", description: "The CSV file's text, header row first" },
        account_id: { type: "string", description: "Account UUID (from get_accounts) to import every row into. Leave out when the CSV has an account column." },
        column_mapping: {
          type: "object",
          description: "Header name to use for a column, overriding detection",
          properties: Assistant::Function::PrepareTradeImport::HEADER_SYNONYMS.keys.index_with { { type: "string" } }
        },
        date_format: { type: "string", description: "strptime format of the date column, e.g. %d/%m/%Y. Detected when left out." },
        number_format: { type: "string", enum: Import::NUMBER_FORMATS.keys, description: "How numbers are written. Defaults to 1,234.56, as the manual import does." },
        signage_convention: { type: "string", enum: Import::SIGNAGE_CONVENTIONS, description: "inflows_positive (default): a positive quantity is a buy" },
        col_sep: { type: "string", enum: Import::SEPARATORS.map(&:last), description: "Column separator. Detected when left out." }
      }
    )
  end

  def call(params = {})
    csv_content = params["csv_content"].to_s
    return error("csv_required", "Pass the CSV text as csv_content.") if csv_content.blank?
    return error("csv_too_large", "The CSV is larger than #{Import.max_csv_size / 1.megabyte} MB.") if csv_content.bytesize > Import.max_csv_size

    account = nil
    if params["account_id"].present?
      return error("invalid_account_id", "account_id must be a UUID from get_accounts.") unless valid_uuid?(params["account_id"])

      account = user.accessible_accounts.find_by(id: params["account_id"])
      return error("account_not_found", "No account with that id is available to this user.") unless account
    end

    col_sep = params["col_sep"].presence || detect_col_sep(csv_content)
    parsed = Import.parse_csv_str(csv_content, col_sep: col_sep)
    headers = Array(parsed.headers).compact
    return error("csv_invalid", "The CSV needs a header row and at least one row of data.") if headers.empty? || parsed.empty?

    mapping = column_mapping(headers, params["column_mapping"], account)
    return mapping if mapping.key?(:error)

    # One transaction, so a refusal raised while the rows are generated (the
    # import's own header check, for one) leaves no pending import behind.
    import = Import.transaction do
      family.imports.create!(
        type: "TradeImport",
        account: account,
        date_format: params["date_format"].presence || detect_date_format(parsed, mapping["date"]),
        number_format: params["number_format"].presence,
        signage_convention: params["signage_convention"].presence || "inflows_positive",
        col_sep: col_sep,
        raw_file_str: csv_content,
        **mapping.transform_keys { |key| :"#{key}_col_label" }
      ).tap do |created|
        created.generate_rows_from_csv
        created.reload.sync_mappings
      end
    end

    summary(import, mapping, headers)
  rescue ActiveRecord::RecordInvalid => e
    error("import_invalid", e.record.errors.full_messages.to_sentence)
  rescue CSV::MalformedCSVError => e
    error("csv_invalid", "The CSV could not be read: #{e.message}")
  end

  private
    # { "date" => "Trade Date", ... } for every key with a column, or an error
    # naming what is missing. Explicit choices must be real headers.
    def column_mapping(headers, explicit, account)
      explicit = (explicit || {}).to_h.transform_keys(&:to_s).compact_blank
      unknown_keys = explicit.keys - HEADER_SYNONYMS.keys
      return error("invalid_column_mapping", "Unknown column keys: #{unknown_keys.join(", ")}.") if unknown_keys.any?

      not_headers = explicit.values - headers
      return error("invalid_column_mapping", "These are not headers in the CSV: #{not_headers.join(", ")}.", headers: headers) if not_headers.any?

      keys = HEADER_SYNONYMS.keys
      keys -= [ "account" ] if account
      by_normal = headers.index_by { |header| normalize(header) }

      mapping = keys.each_with_object({}) do |key, chosen|
        header = explicit[key] || HEADER_SYNONYMS[key].lazy.map { |synonym| by_normal[synonym] }.find(&:present?)
        chosen[key] = header if header
      end

      required = TradeImport.new(account: account).required_column_keys.map(&:to_s)
      missing = required - mapping.keys
      if missing.any?
        return error(
          "columns_not_found",
          "No column was found for: #{missing.join(", ")}. Pass column_mapping with the header names to use.",
          headers: headers, detected: mapping
        )
      end

      mapping
    end

    def summary(import, mapping, headers)
      rows = import.rows.ordered.to_a
      invalid = rows.reject(&:valid?)

      {
        import_id: import.id,
        status: "pending",
        account: import.account && { id: import.account.id, name: import.account.name },
        column_mapping: mapping,
        unmapped_headers: headers - mapping.values,
        date_format: import.date_format,
        number_format: import.number_format,
        signage_convention: import.signage_convention,
        rows_count: rows.size,
        valid_rows_count: rows.size - invalid.size,
        invalid_rows: invalid.first(MAX_INVALID_ROWS_REPORTED).map do |row|
          { row_number: row.source_row_number, errors: row.errors.full_messages }
        end,
        accounts_to_create: import.account ? 0 : Import::AccountMapping.for_import(import).creational.count,
        tickers: rows.map(&:ticker).compact_blank.uniq.sort,
        sample_rows: rows.first(SAMPLE_ROWS).map do |row|
          { row_number: row.source_row_number, date: row.date, ticker: row.ticker, qty: row.qty, price: row.price, currency: row.currency, account: row.account.presence }.compact
        end,
        note: "Nothing has been imported. The import is pending; it can be reviewed and published from the imports page."
      }
    end

    def normalize(header)
      header.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def detect_col_sep(csv_content)
      first_line = csv_content.lines.first.to_s
      first_line.count(";") > first_line.count(",") ? ";" : ","
    end

    def detect_date_format(parsed, date_header)
      samples = parsed.first(50).map { |row| row[date_header] }
      Import.detect_date_format(samples, candidates: Family::DATE_FORMATS.map(&:last) + Import::CSV_ONLY_DATE_FORMATS.map(&:last), fallback: family.date_format)
    end

    def error(key, message, **details)
      { error: key, message: message, **details }
    end
end
