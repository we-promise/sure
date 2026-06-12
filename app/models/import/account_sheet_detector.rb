# Detects which worksheets in an uploaded .xlsx represent importable accounts,
# and how to read each one. Built for French bank exports (Crédit Mutuel / CIC),
# but driven by the file's own structure so new accounts in future exports are
# picked up automatically without code changes.
#
# Two detection strategies, in order of preference:
#
#   1. Manifest (preferred): CM/CIC exports ship a very-hidden "hidden_data"
#      sheet listing every account sheet with its data Range and Type
#      (cpt / cb). This is the robust path — a new account is simply a new row
#      in that manifest.
#
#   2. Heuristic (fallback): when no manifest is present, we recognise the two
#      known table layouts by their header row:
#        - "Date | Valeur | Libellé | Débit | Crédit | Solde"  => :cpt
#        - "Date | Libellé | Montant"                          => :cb
#
# The stable key for matching a sheet to an app account is the account number
# embedded in the sheet name (e.g. "02619 00044047901"). The human-readable
# name and balance come from the "Vos comptes" summary sheet when present.
# Credit-card sheets change name every month ("# 052026" -> "# 062026"); keying
# on the account number keeps them mapped to the same account over time.
class Import::AccountSheetDetector
  SUMMARY_SHEET_NAME = "Vos comptes".freeze
  MANIFEST_SHEET_NAMES = %w[hidden_data hidden].freeze

  # A sheet's account number as it appears in the tab name: a 5-digit branch
  # code, a space, then the 11-digit account number.
  ACCOUNT_NUMBER_RE = /(\d{5}\s+\d{6,})/

  SAMPLE_SIZE = 5

  DetectedSheet = Struct.new(
    :sheet_name, :type, :account_number, :account_name, :currency,
    :header_row, :first_data_row, :last_data_row, :columns, :sample,
    keyword_init: true
  ) do
    # Stable, whitespace-insensitive key used to match an existing app account.
    def account_key
      account_number.to_s.gsub(/\s+/, "")
    end

    def row_count
      return nil unless first_data_row && last_data_row
      [ last_data_row - first_data_row + 1, 0 ].max
    end
  end

  def initialize(workbook)
    @workbook = workbook
  end

  def detected_sheets
    @detected_sheets ||= (manifest_entries.presence || heuristic_entries).filter_map do |entry|
      build_detected_sheet(entry)
    end
  end

  # All importable transactions for a detected sheet, as
  # [{ date: Date, name: String, amount: BigDecimal, currency: String }].
  # Rows without a parseable date or with a blank/zero amount (informational
  # lines such as "NOUVEAU TAUX DU LIVRET...") are skipped.
  def transactions(detected)
    matrix = workbook.cell_matrix(detected.sheet_name)
    parse_rows(matrix, detected.columns, detected.first_data_row, detected.last_data_row, detected.currency)
  end

  private
    attr_reader :workbook

    # --- Strategy 1: manifest ------------------------------------------------

    # Returns [{ sheet_name:, type:, range: }] from the hidden manifest, or [].
    def manifest_entries
      @manifest_entries ||= load_manifest_entries
    end

    def load_manifest_entries
      sheet = workbook.sheets.find { |s| MANIFEST_SHEET_NAMES.include?(s.name) && s.path }
      return [] unless sheet

      matrix = workbook.cell_matrix(sheet.name)
      header_row = find_row(matrix) { |cells| row_has?(cells, "nom du compte") && row_has?(cells, "type") }
      return [] unless header_row

      cols = header_columns(matrix[header_row])
      name_col  = cols["nom du compte"]
      range_col = cols["range"]
      type_col  = cols["type"]
      return [] unless name_col && type_col

      entries = []
      ((header_row + 1)..matrix.keys.max).each do |r|
        cells = matrix[r] || {}
        name = cells[name_col].to_s.strip
        break if name.blank? # stop at the first gap (templates live below)

        type = normalize(cells[type_col].to_s)
        next unless %w[cpt cb].include?(type)
        next unless workbook.sheet(name) # manifest may reference removed sheets

        entries << { sheet_name: name, type: type.to_sym, range: cells[range_col].to_s.strip }
      end
      entries
    end

    # --- Strategy 2: heuristic ----------------------------------------------

    def heuristic_entries
      workbook.visible_account_candidate_sheets.filter_map do |sheet|
        matrix = workbook.cell_matrix(sheet.name, max_rows: 30)
        header_row = find_row(matrix) { |cells| row_has?(cells, "date") && row_has?(cells, "libelle") }
        next unless header_row

        cells = matrix[header_row]
        type =
          if row_has?(cells, "debit") || row_has?(cells, "credit") then :cpt
          elsif row_has?(cells, "montant") then :cb
          end
        next unless type

        { sheet_name: sheet.name, type: type, range: nil, header_row: header_row }
      end
    end

    # --- Build a DetectedSheet ----------------------------------------------

    def build_detected_sheet(entry)
      sheet_name = entry[:sheet_name]
      matrix = workbook.cell_matrix(sheet_name)
      return nil if matrix.empty?

      header_row = entry[:header_row] || find_row(matrix) do |cells|
        row_has?(cells, "date") && (row_has?(cells, "libelle") || row_has?(cells, "montant"))
      end
      return nil unless header_row

      columns = column_roles(matrix[header_row], entry[:type])
      first_data_row, last_data_row = data_bounds(entry[:range], header_row, matrix)

      account_number = extract_account_number(sheet_name)
      currency = detect_currency(matrix, columns, first_data_row) || "EUR"

      DetectedSheet.new(
        sheet_name: sheet_name,
        type: entry[:type],
        account_number: account_number,
        account_name: summary_index[normalize_key(account_number)] || fallback_name(sheet_name),
        currency: currency,
        header_row: header_row,
        first_data_row: first_data_row,
        last_data_row: last_data_row,
        columns: columns,
        sample: build_sample(matrix, columns, first_data_row, last_data_row, currency)
      )
    end

    # Locate columns by header text (accent/spacing-insensitive), positional
    # fallback per known layout if a header is missing.
    def column_roles(header_cells, type)
      cols = header_columns(header_cells)
      if type == :cpt
        {
          date: cols["date"] || 1,
          name: cols["libelle"] || 3,
          debit: cols["debit"] || 4,
          credit: cols["credit"] || 5,
          currency: cols["dev"] || 7
        }
      else # :cb
        {
          date: cols["date"] || 1,
          name: cols["libelle"] || 2,
          amount: cols["montant"] || 3,
          currency: cols["dev"] || 4
        }
      end
    end

    def data_bounds(range, header_row, matrix)
      if range.present? && (m = range.match(/[A-Z]+(\d+):[A-Z]+(\d+)/i))
        [ m[1].to_i, m[2].to_i ]
      else
        [ header_row + 1, matrix.keys.max ]
      end
    end

    def build_sample(matrix, columns, first_data_row, last_data_row, currency)
      parse_rows(matrix, columns, first_data_row, last_data_row, currency, limit: SAMPLE_SIZE)
    end

    # Shared row parser for both the preview sample and the real import.
    def parse_rows(matrix, columns, first_data_row, last_data_row, currency, limit: nil)
      return [] unless first_data_row

      last = last_data_row || matrix.keys.max
      result = []
      (first_data_row..last).each do |r|
        cells = matrix[r]
        next unless cells

        date = Import::XlsxWorkbook.excel_serial_to_date(cells[columns[:date]])
        next unless date

        amount = row_amount(cells, columns)
        next if amount.nil? || amount.zero? # skip blank/informational lines

        result << {
          date: date,
          name: cells[columns[:name]].to_s.strip,
          amount: amount,
          currency: (cells[columns[:currency]].presence || currency)
        }
        break if limit && result.size >= limit
      end
      result
    end

    # cpt: amount is the credit, or the debit when there's no credit (both are
    # already signed in the export). cb: a single signed Montant column.
    def row_amount(cells, columns)
      if columns.key?(:amount)
        to_decimal(cells[columns[:amount]])
      else
        credit = cells[columns[:credit]]
        debit  = cells[columns[:debit]]
        to_decimal(credit.present? ? credit : debit)
      end
    end

    # --- Summary ("Vos comptes") --------------------------------------------

    def summary_index
      @summary_index ||= load_summary_index
    end

    def load_summary_index
      sheet = workbook.sheet(SUMMARY_SHEET_NAME)
      return {} unless sheet&.path

      matrix = workbook.cell_matrix(sheet.name)
      header_row = find_row(matrix) { |cells| row_has?(cells, "compte") && row_has?(cells, "r.i.b.") }
      return {} unless header_row

      cols = header_columns(matrix[header_row])
      name_col = cols["compte"]
      rib_col  = cols["r.i.b."] || cols["rib"]
      return {} unless name_col && rib_col

      index = {}
      ((header_row + 1)..matrix.keys.max).each do |r|
        cells = matrix[r] || {}
        rib = cells[rib_col].to_s
        name = cells[name_col].to_s.strip
        number = extract_account_number(rib)
        next if number.blank? || name.blank?

        # Keep the first (canonical) name per account; later rows are
        # card-expense roll-ups sharing the same RIB.
        index[normalize_key(number)] ||= name
      end
      index
    end

    # --- Helpers -------------------------------------------------------------

    def extract_account_number(text)
      text.to_s[ACCOUNT_NUMBER_RE, 1]&.strip
    end

    def normalize_key(number)
      number.to_s.gsub(/\s+/, "")
    end

    def fallback_name(sheet_name)
      sheet_name.sub(/\s*#\s*\d+\s*\z/, "").strip
    end

    def detect_currency(matrix, columns, first_data_row)
      return nil unless first_data_row && columns[:currency]
      cell = matrix.dig(first_data_row, columns[:currency])
      cell.presence&.strip
    end

    # Map normalized header text => column index for a header row.
    def header_columns(cells)
      (cells || {}).each_with_object({}) do |(col, value), acc|
        key = normalize(value)
        acc[key] = col unless key.blank? || acc.key?(key)
      end
    end

    def row_has?(cells, normalized_needle)
      (cells || {}).any? { |_col, value| normalize(value).include?(normalized_needle) }
    end

    def find_row(matrix)
      matrix.keys.sort.find { |r| yield(matrix[r]) }
    end

    # Accent- and case-insensitive, trimmed. "Libellé" -> "libelle".
    def normalize(value)
      value.to_s
           .unicode_normalize(:nfkd)
           .gsub(/\p{Mn}/, "")
           .downcase
           .strip
    end

    def to_decimal(value)
      return nil if value.nil? || value.to_s.strip.empty?
      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
