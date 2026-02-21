class FidelityImport < Import
  after_create :set_mappings

  # Action prefix → [entity_type, activity_label]
  # entity_type: "trade" or "transaction" or "skip"
  ACTION_MAP = {
    "REINVESTMENT"                => ["trade", "Reinvestment"],
    "YOU BOUGHT"                  => ["trade", "Buy"],
    "YOU SOLD"                    => ["trade", "Sell"],
    "DIVIDEND RECEIVED"           => ["transaction", "Dividend"],
    "SHORT-TERM CAP GAIN"        => ["transaction", "Dividend"],
    "LONG-TERM CAP GAIN"         => ["transaction", "Dividend"],
    "DISTRIBUTION"                => ["transaction", "Dividend"],
    "FEE CHARGED"                 => ["transaction", "Fee"],
    "Electronic Funds Transfer"   => ["transaction", "Transfer"],
  }.freeze

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.filter_map do |row|
      action = row[entity_type_col_label].to_s.strip
      next if action.blank?

      # Skip "DIV OF $X PENDING REINVESTMENT" informational rows
      next if action.match?(/PENDING REINVESTMENT/i)

      # Strip trailing "(Cash)" and quotes from action
      clean_action = action.gsub(/\s*\(Cash\)\s*$/, "").strip

      entity_type, activity_label = classify_action(clean_action)
      next if entity_type == "skip"

      {
        date: row[date_col_label].to_s.strip,
        ticker: row[ticker_col_label].to_s.strip,
        qty: sanitize_number(row[qty_col_label]).to_s,
        price: sanitize_number(row[price_col_label]).to_s,
        amount: sanitize_number(row[amount_col_label]).to_s,
        currency: (row[currency_col_label] || default_currency).to_s.strip,
        name: build_row_name(clean_action, row[ticker_col_label].to_s.strip, activity_label),
        entity_type: "#{entity_type}:#{activity_label}",
        notes: clean_action
      }
    end

    rows.insert_all!(mapped_rows) if mapped_rows.any?
    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      new_trades = []
      new_transactions = []

      rows.each do |row|
        entity_type, activity_label = row.entity_type.to_s.split(":", 2)
        mapped_account = account

        next if mapped_account.nil?

        effective_currency = row.currency.presence || mapped_account.currency || family.currency

        if entity_type == "trade" && row.ticker.present?
          security = find_or_create_security(ticker: row.ticker)
          next unless security

          qty = row.qty.to_d
          # Reinvestments are always buys (positive qty)
          qty = qty.abs if activity_label == "Reinvestment"
          # Sells should have negative qty
          qty = -qty.abs if activity_label == "Sell" && qty.positive?

          new_trades << Trade.new(
            security: security,
            qty: qty,
            price: row.price.to_d,
            currency: effective_currency,
            investment_activity_label: activity_label,
            entry: Entry.new(
              account: mapped_account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: effective_currency,
              notes: row.notes,
              import: self,
              import_locked: true
            )
          )
        elsif entity_type == "transaction"
          new_transactions << Transaction.new(
            kind: activity_label == "Transfer" ? "investment_contribution" : "standard",
            entry: Entry.new(
              account: mapped_account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: effective_currency,
              notes: row.notes,
              import: self,
              import_locked: true
            )
          )
        end
      end

      Trade.import!(new_trades, recursive: true) if new_trades.any?
      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date entity_type ticker price qty amount currency name]
  end

  def mapping_steps
    []
  end

  def dry_run
    trade_count = rows.where("entity_type LIKE 'trade:%'").count
    transaction_count = rows.where("entity_type LIKE 'transaction:%'").count
    { transactions: trade_count + transaction_count }
  end

  def csv_template
    template = <<-CSV
      Run Date*,Action*,Symbol,Description,Type,Exchange Quantity,Exchange Currency,Currency,Price,Quantity,Exchange Rate,Commission,Fees,Accrued Interest,Amount*,Cash Balance,Settlement Date
      02/19/2026,"DIVIDEND RECEIVED MAIN STR CAP CORP (MAIN) (Cash)",MAIN,"MAIN STR CAP CORP",Cash,0,,USD,,0.000,0,,,,7.94,,
      02/19/2026,"REINVESTMENT MAIN STR CAP CORP (MAIN) (Cash)",MAIN,"MAIN STR CAP CORP",Cash,0,,USD,60.89,0.13,0,,,,-7.94,,
      02/19/2026,"YOU BOUGHT WILLIAMS-SONOMA INC (WSM) (Cash)",WSM,"WILLIAMS-SONOMA INC",Cash,0,,USD,175.35,0.388,0,,,,-68.04,,
    CSV
    CSV.parse(template, headers: true)
  end

  private
    def set_mappings
      self.col_sep = ","
      self.signage_convention = "inflows_positive"
      self.date_col_label = "Run Date"
      self.date_format = "%m/%d/%Y"
      self.amount_col_label = "Amount"
      self.currency_col_label = "Currency"
      self.entity_type_col_label = "Action"
      self.ticker_col_label = "Symbol"
      self.price_col_label = "Price"
      self.qty_col_label = "Quantity"
      self.name_col_label = "Description"
      self.amount_type_strategy = "signed_amount"
      self.rows_to_skip = 2
      save!
    end

    def classify_action(action)
      ACTION_MAP.each do |prefix, result|
        return result if action.start_with?(prefix)
      end
      ["skip", nil]
    end

    def build_row_name(action, ticker, activity_label)
      case activity_label
      when "Dividend" then "Dividend - #{ticker}"
      when "Reinvestment" then "Reinvest dividend - #{ticker}"
      when "Buy" then "Buy #{ticker}"
      when "Sell" then "Sell #{ticker}"
      when "Transfer" then "Transfer received"
      when "Fee" then "Fee charged"
      else action.truncate(60)
      end
    end

    def find_or_create_security(ticker:)
      return nil if ticker.blank?
      @security_cache ||= {}
      return @security_cache[ticker] if @security_cache.key?(ticker)

      # Skip SPAXX (money market fund) — not a real security to track
      if ticker.upcase == "SPAXX"
        @security_cache[ticker] = nil
        return nil
      end

      security = Security::Resolver.new(ticker).resolve
      @security_cache[ticker] = security
      security
    end
end
