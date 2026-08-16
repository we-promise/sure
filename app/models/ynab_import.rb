class YnabImport < Import
  after_create :set_mappings

  DEFAULT_COLUMN_MAPPINGS = {
    signage_convention: "inflows_positive",
    date_col_label: "Date",
    date_format: "%m/%d/%Y",
    name_col_label: "Payee",
    account_col_label: "Account",
    category_col_label: "Category",
    notes_col_label: "Memo"
  }.freeze

  # YNAB register exports always use these literal headers; they aren't surfaced as
  # remappable column labels because the amount and category are derived from them.
  OUTFLOW_COLUMN = "Outflow".freeze
  INFLOW_COLUMN = "Inflow".freeze
  # Modern (web) YNAB carries a pre-combined column plus the split group/leaf pair.
  COMBINED_CATEGORY_COLUMN = "Category Group/Category".freeze
  CATEGORY_GROUP_COLUMN = "Category Group".freeze
  # Legacy YNAB 4 (classic) exports split the category differently.
  MASTER_CATEGORY_COLUMN = "Master Category".freeze
  SUB_CATEGORY_COLUMN = "Sub Category".freeze

  def self.default_column_mappings
    DEFAULT_COLUMN_MAPPINGS
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map.with_index(1) do |row, index|
      {
        source_row_number: index,
        account: csv_value(row, account_col_label, "account", "account_name").to_s,
        date: csv_value(row, date_col_label, "date").to_s,
        amount: signed_csv_amount(row).to_s,
        currency: default_currency.to_s,
        name: row_name(row),
        category: combined_category(row),
        notes: csv_value(row, notes_col_label, "notes", "memo").to_s
      }
    end

    rows.insert_all!(mapped_rows)
    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      rows.each do |row|
        account = mappings.accounts.mappable_for(row.account)
        category = mappings.categories.mappable_for(row.category)

        entry = account.entries.build \
          date: row.date_iso,
          amount: row.signed_amount,
          name: row.name,
          currency: account.currency.presence || family.currency,
          notes: row.notes,
          entryable: Transaction.new(category: category),
          import: self

        entry.save!
      end
    end
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::AccountMapping ]
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date name category account notes]
  end

  def csv_template
    template = <<~CSV
      Account,Flag,Date,Payee,Category Group/Category,Category Group,Category,Memo,Outflow,Inflow,Cleared
      Checking,,01/01/2024,Employer,Income: Paycheck,Income,Paycheck,Monthly salary,$0.00,$2500.00,Cleared
      Credit Card,,01/03/2024,Coffee Shop,Dining Out: Coffee,Dining Out,Coffee,Morning coffee,$4.25,$0.00,Uncleared
    CSV

    CSV.parse(template, headers: true)
  end

  # YNAB splits money movement across Outflow and Inflow columns (positive
  # magnitudes) rather than a single signed amount. Combine them into the
  # "inflows positive" convention the framework expects — Import::Row reverses it
  # to Sure's internal "outflows positive" signage. A single signed Amount column,
  # when present, takes precedence (some hand-built exports use one).
  def signed_csv_amount(csv_row)
    explicit = csv_value(csv_row, amount_col_label.presence || "Amount")
    return sanitize_number(explicit).to_d if explicit.present?

    # If the file exposes no recognizable amount source (wrong file or renamed
    # headers), leave the amount blank so the required-column validation blocks the
    # import rather than silently creating zero-dollar entries.
    return nil unless amount_source_columns?

    inflow  = sanitize_number(csv_value(csv_row, INFLOW_COLUMN)).to_d
    outflow = sanitize_number(csv_value(csv_row, OUTFLOW_COLUMN)).to_d

    inflow - outflow.abs
  end

  private
    def set_mappings
      assign_attributes(self.class.default_column_mappings)
      save!
    end

    # True when the uploaded file has at least one column the amount can be derived
    # from: Outflow, Inflow, or a single signed Amount.
    def amount_source_columns?
      header_for(OUTFLOW_COLUMN).present? ||
        header_for(INFLOW_COLUMN).present? ||
        header_for(amount_col_label.presence || "Amount").present?
    end

    # YNAB exports starting-balance / reconciliation rows with a blank Payee. Entry
    # requires a name, so fall back to the Memo column and finally the generic
    # default, mirroring the blank-name handling in Import and ActualImport.
    def row_name(row)
      csv_value(row, name_col_label, "payee").to_s.presence ||
        csv_value(row, notes_col_label, "memo").to_s.presence ||
        default_row_name
    end

    # Resolve a single category string across YNAB export shapes:
    #   - modern web YNAB: a pre-combined "Category Group/Category" column
    #   - modern web YNAB (split): "Category Group" + "Category"
    #   - legacy YNAB 4: "Master Category" + "Sub Category"
    #   - simplified exports: a single "Category" column already holding the full value
    def combined_category(row)
      combined = csv_value(row, COMBINED_CATEGORY_COLUMN)
      return combined.to_s.strip if combined.present?

      group = csv_value(row, CATEGORY_GROUP_COLUMN).to_s.strip
      return join_category(group, csv_value(row, category_col_label, "category")) if group.present?

      master = csv_value(row, MASTER_CATEGORY_COLUMN).to_s.strip
      sub = csv_value(row, SUB_CATEGORY_COLUMN).to_s.strip
      return join_category(master, sub) if master.present? || sub.present?

      csv_value(row, category_col_label, "category").to_s.strip
    end

    def join_category(group, category)
      category = category.to_s.strip
      return category if group.blank?
      return group if category.blank?

      "#{group}: #{category}"
    end
end
