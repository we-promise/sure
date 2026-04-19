class YnabImport < Import
  after_create :set_mappings

  OUTFLOW_COL = "Outflow".freeze
  INFLOW_COL = "Inflow".freeze

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map do |row|
      {
        account: row[account_col_label].to_s,
        date: row[date_col_label].to_s,
        amount: compute_signed_amount(row).to_s("F"),
        currency: default_currency.to_s,
        name: (row[name_col_label] || default_row_name).to_s,
        category: row[category_col_label].to_s,
        tags: row[tags_col_label].to_s,
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
        mapped_account = if account
          account
        else
          mappings.accounts.mappable_for(row.account)
        end
        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        effective_currency = mapped_account.currency.presence || family.currency

        entry = mapped_account.entries.build \
          date: row.date_iso,
          amount: row.signed_amount,
          name: row.name,
          currency: effective_currency,
          notes: row.notes,
          entryable: Transaction.new(category: category, tags: tags),
          import: self

        entry.save!
      end
    end
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::TagMapping, Import::AccountMapping ]
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount name currency category tags account notes]
  end

  def csv_template
    template = <<-CSV
      Account,Flag,Date,Payee,Category Group/Category,Category Group,Category,Memo,Outflow,Inflow,Cleared
      Checking,,01/15/2024,Grocery Store,Immediate Obligations: Groceries,Immediate Obligations,Groceries,Weekly groceries,$78.32,$0.00,Cleared
      Checking,,01/16/2024,ACME Corp,Income: Salary,Income,Salary,Bi-weekly paycheck,$0.00,"$2,500.00",Cleared
      Credit Card,,01/17/2024,Coffee Shop,Quality of Life: Dining Out,Quality of Life,Dining Out,Morning coffee,$4.25,$0.00,Cleared
    CSV

    CSV.parse(template, headers: true)
  end

  private
    # YNAB uses two columns: Outflow (expenses) and Inflow (income).
    # In Sure, positive = outflow (expense), negative = inflow (income).
    def compute_signed_amount(csv_row)
      outflow = sanitize_ynab_amount(csv_row[OUTFLOW_COL])
      inflow = sanitize_ynab_amount(csv_row[INFLOW_COL])
      outflow - inflow
    end

    def sanitize_ynab_amount(value)
      return 0.to_d if value.blank?

      # Strip currency symbols, spaces, then normalize number format
      cleaned = value.to_s.gsub(/[^\d.,\-]/, "")
      return 0.to_d if cleaned.blank?

      # Handle comma as thousands separator (US format: $2,500.00)
      cleaned.gsub(",", "").to_d
    end

    def set_mappings
      self.signage_convention = "inflows_negative"
      self.date_col_label = "Date"
      self.date_format = "%m/%d/%Y"
      self.name_col_label = "Payee"
      # YNAB uses dual Outflow/Inflow columns merged by compute_signed_amount,
      # but amount_col_label is required for the configuration step validation.
      self.amount_col_label = OUTFLOW_COL
      self.account_col_label = "Account"
      self.category_col_label = "Category"
      self.notes_col_label = "Memo"

      save!
    end
end
