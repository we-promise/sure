class BuddyImport < Import
  after_create :set_mappings

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map do |row|
      {
        date: row[date_col_label].to_s,
        amount: sanitize_number(row[amount_col_label]).to_s,
        currency: (row[currency_col_label] || default_currency).to_s,
        name: (row[name_col_label] || default_row_name).to_s,
        category: row[category_col_label].to_s,
        category_parent: row[category_parent_col_label].to_s,
        paid_by: row[paid_by_col_label].to_s,
        notes: row[notes_col_label].to_s
      }
    end

    rows.insert_all!(mapped_rows)
    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      updated_entries = []
      claimed_entry_ids = Set.new

      rows.each_with_index do |row, index|
        mapped_account = account

        if mapped_account.nil?
          raise Import::MappingError, "Row #{index + 1}: No account selected"
        end

        category = resolve_hierarchical_category(row.category, row.category_parent)
        effective_currency = row.currency.presence || mapped_account.currency || family.currency

        # Skip $0 transfers (Buddy uses $0 for savings movements between accounts)
        next if row.signed_amount.zero?

        adapter = Account::ProviderImportAdapter.new(mapped_account)
        duplicate_entry = adapter.find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: effective_currency,
          name: row.name,
          exclude_entry_ids: claimed_entry_ids
        )

        if duplicate_entry
          duplicate_entry.transaction.category = category if category.present?
          duplicate_entry.notes = row.notes if row.notes.present?
          duplicate_entry.import = self
          duplicate_entry.import_locked = true
          updated_entries << duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)
        else
          new_transactions << Transaction.new(
            category: category,
            entry: Entry.new(
              account: mapped_account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: effective_currency,
              notes: build_notes(row),
              import: self,
              import_locked: true
            )
          )
        end
      end

      updated_entries.each do |entry|
        entry.transaction.save!
        entry.save!
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  def mapping_steps
    [ Import::BuddyCategoryMapping ]
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount name currency category category_parent paid_by notes]
  end

  def dry_run
    {
      transactions: rows_count,
      categories: Import::BuddyCategoryMapping.for_import(self).creational.count
    }
  end

  def csv_template
    template = <<-CSV
      Date*,Amount*,Note,Currency,Category,Head categor,Paid By
      2026-01-15,-45.99,Grocery Store,USD,Groceries,Food & drinks,Juan
      2026-01-16,1500.00,Paycheck,USD,Salary,Income,Juan
      2026-01-17,-12.50,Coffee Shop,USD,Eating Out,Food & drinks,Kathya
    CSV

    CSV.parse(template, headers: true)
  end

  private
    def set_mappings
      self.col_sep = ";"
      self.signage_convention = "inflows_positive"
      self.date_col_label = "Date"
      self.date_format = "%Y-%m-%d"
      self.amount_col_label = "Amount"
      self.currency_col_label = "Currency"
      self.name_col_label = "Note"
      self.category_col_label = "Category"
      self.category_parent_col_label = "Head categor"
      self.paid_by_col_label = "Paid By"
      self.notes_col_label = nil
      self.amount_type_strategy = "signed_amount"
      save!
    end

    def resolve_hierarchical_category(child_name, parent_name)
      parent_name = parent_name.to_s.strip
      child_name = child_name.to_s.strip

      return nil if child_name.blank? && parent_name.blank?

      # Category name is unique per family (not per parent), so we use
      # find_or_create_by!(name:) and set parent only on new records.

      parent = nil
      if parent_name.present?
        parent = family.categories.find_or_create_by!(name: parent_name) do |cat|
          cat.classification = infer_classification(parent_name)
          cat.color = Category::UNCATEGORIZED_COLOR
          cat.lucide_icon = "shapes"
        end
      end

      if child_name.present? && child_name != parent_name
        family.categories.find_or_create_by!(name: child_name) do |cat|
          cat.parent = parent
          cat.classification = parent&.classification || "expense"
          cat.color = Category::UNCATEGORIZED_COLOR
          cat.lucide_icon = "shapes"
        end
      else
        parent
      end
    end

    def infer_classification(category_name)
      case category_name.downcase
      when "income" then "income"
      else "expense"
      end
    end

    def build_notes(row)
      "Paid by: #{row.paid_by}" if row.paid_by.present?
    end
end
