class ActualImport < Import
  after_create :set_mappings

  DEFAULT_COLUMN_MAPPINGS = {
    signage_convention: "inflows_positive",
    date_col_label: "Date",
    date_format: "%Y-%m-%d",
    name_col_label: "Payee",
    amount_col_label: "Amount",
    account_col_label: "Account",
    category_col_label: "Category",
    notes_col_label: "Notes"
  }.freeze

  CATEGORY_GROUP_COLUMN = "Category_Group".freeze

  def self.default_column_mappings
    DEFAULT_COLUMN_MAPPINGS
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map.with_index(1) do |row, index|
      {
        source_row_number: index,
        account: row[account_col_label].to_s,
        date: row[date_col_label].to_s,
        amount: signed_csv_amount(row).to_s,
        currency: default_currency.to_s,
        name: row_name(row),
        category: combined_category(row),
        notes: row[notes_col_label].to_s
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
    %i[date amount name category account notes]
  end

  def csv_template
    template = <<~CSV
      Account,Date,Payee,Notes,Category_Group,Category,Amount,Split_Amount,Cleared
      Checking Account,2024-01-01,Employer,Monthly salary,Income,Paycheck,2500.00,0,Reconciled
      Credit Card,2024-01-03,Coffee Shop,Morning coffee,Food,Coffee,-4.25,0,Cleared
    CSV

    CSV.parse(template, headers: true)
  end

  def signed_csv_amount(csv_row)
    csv_row[amount_col_label].to_d
  end

  private
    def set_mappings
      assign_attributes(self.class.default_column_mappings)
      save!
    end

    # Actual Budget exports reconciliation and starting-balance rows with a blank
    # Payee. Entry requires a name, so fall back to the Notes column (which usually
    # carries text like "Reconciliation balance adjustment") and finally to the
    # generic default, matching the blank-name handling in Import and MintImport.
    def row_name(row)
      row[name_col_label].to_s.presence ||
        row[notes_col_label].to_s.presence ||
        default_row_name
    end

    def combined_category(row)
      category = row[category_col_label].to_s.strip
      category_group = row[CATEGORY_GROUP_COLUMN].to_s.strip

      return category if category_group.blank?
      return category_group if category.blank?

      "#{category_group}: #{category}"
    end
end
