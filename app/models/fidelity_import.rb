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
      @duplicate_count = 0

      # Pre-load existing entries on this account for dedup
      existing_entries = load_existing_entries

      rows.each do |row|
        entity_type, activity_label = row.entity_type.to_s.split(":", 2)
        mapped_account = account

        next if mapped_account.nil?

        effective_currency = row.currency.presence || mapped_account.currency || family.currency
        row_date = row.date_iso
        row_amount = row.signed_amount

        if entity_type == "trade" && row.ticker.present?
          security = find_or_create_security(ticker: row.ticker)
          next unless security

          if duplicate_entry?(existing_entries, row_date, row_amount, row.ticker)
            @duplicate_count += 1
            next
          end

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
              date: row_date,
              amount: row_amount,
              name: row.name,
              currency: effective_currency,
              notes: row.notes,
              import: self,
              import_locked: true
            )
          )
        elsif entity_type == "transaction"
          if duplicate_entry?(existing_entries, row_date, row_amount, nil)
            @duplicate_count += 1
            next
          end

          new_transactions << Transaction.new(
            kind: activity_label == "Transfer" ? "investment_contribution" : "standard",
            entry: Entry.new(
              account: mapped_account,
              date: row_date,
              amount: row_amount,
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

      # Create opening balance trades from positions CSV if present
      opening_balance_trades = build_opening_balance_trades
      Trade.import!(opening_balance_trades, recursive: true) if opening_balance_trades.any?

      Rails.logger.info("[FidelityImport] Imported #{new_trades.size} trades, #{new_transactions.size} transactions, #{opening_balance_trades.size} opening balances, skipped #{@duplicate_count} duplicates")
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
    existing_entries = load_existing_entries
    dupes = 0

    rows.each do |row|
      row_date = (Date.strptime(row.date, date_format).iso8601 rescue nil)
      next unless row_date
      row_amount = row.signed_amount
      ticker = row.ticker.presence
      dupes += 1 if duplicate_entry?(existing_entries, row_date, row_amount, ticker)
    end

    trade_count = rows.where("entity_type LIKE 'trade:%'").count
    transaction_count = rows.where("entity_type LIKE 'transaction:%'").count

    result = { transactions: trade_count + transaction_count - dupes, duplicates: dupes }
    result[:opening_balances] = count_opening_balances if positions_file_str.present?
    result
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

  # Returns the list of account numbers found in the positions CSV, if multi-account
  def positions_account_numbers
    return [] unless positions_file_str.present?
    parse_positions_csv.keys.sort
  end

  # The currently selected positions account number (stored in extracted_data)
  def positions_account_number
    extracted_data&.dig("positions_account_number")
  end

  def positions_account_number=(value)
    self.extracted_data = (extracted_data || {}).merge("positions_account_number" => value)
  end

  private
    def parse_positions_csv
      return {} unless positions_file_str.present?
      @parsed_positions ||= parse_positions_csv_str(positions_file_str)
    end

    # Parses Fidelity positions CSV format. Returns hash grouped by account number:
    # { "Z12345678" => { "AAPL" => { qty: 10.0, price: 150.0 }, ... } }
    #
    # Fidelity positions CSVs typically have:
    # - Header rows to skip (account info lines before the actual CSV)
    # - Columns: Account Number, Symbol, Description, Quantity, Last Price, ...
    def parse_positions_csv_str(csv_str)
      lines = csv_str.strip.lines

      # Find the header row — look for a line containing "Symbol" and "Quantity"
      header_idx = lines.index { |l| l.match?(/Symbol/i) && l.match?(/Quantity/i) }
      return {} unless header_idx

      csv_content = lines[header_idx..].join
      parsed = CSV.parse(csv_content, headers: true, liberal_parsing: true, converters: [ ->(s) { s&.strip } ])

      # Detect column names (Fidelity uses various formats)
      account_col = parsed.headers.find { |h| h&.match?(/Account.*Number|Account/i) }
      symbol_col = parsed.headers.find { |h| h&.match?(/\ASymbol\z/i) }
      qty_col = parsed.headers.find { |h| h&.match?(/Quantity/i) }
      price_col = parsed.headers.find { |h| h&.match?(/Last Price|Current Value/i) } ||
                  parsed.headers.find { |h| h&.match?(/Price/i) }

      return {} unless symbol_col && qty_col

      accounts = {}

      parsed.each do |row|
        ticker = row[symbol_col].to_s.strip
        next if ticker.blank? || ticker.match?(/^-+$/) || ticker.upcase == "SPAXX"
        next if ticker.match?(/pending/i)

        # Clean ticker — remove trailing asterisk or other annotations
        ticker = ticker.gsub(/\*+$/, "").strip
        next if ticker.blank?

        qty = sanitize_number(row[qty_col]).to_d
        next if qty.zero?

        price = price_col ? sanitize_number(row[price_col]).to_d : 0
        acct_num = account_col ? row[account_col].to_s.strip : "default"
        acct_num = "default" if acct_num.blank?

        accounts[acct_num] ||= {}
        accounts[acct_num][ticker.upcase] = { qty: qty, price: price }
      end

      accounts
    end

    # Returns the positions hash for the selected account (or the only account)
    def selected_positions
      positions = parse_positions_csv
      return {} if positions.empty?

      if positions.size == 1
        positions.values.first
      elsif positions_account_number.present?
        positions[positions_account_number] || {}
      else
        # No account selected yet — return empty
        {}
      end
    end

    # Count how many opening balance trades would be created
    def count_opening_balances
      positions = selected_positions
      return 0 if positions.empty? || account.nil?

      # Calculate net qty per ticker from existing import rows
      imported_qty = net_qty_from_rows

      # Also check for existing opening balance entries on the account
      existing_opening_tickers = existing_opening_balance_tickers

      count = 0
      positions.each do |ticker, pos_data|
        next if existing_opening_tickers.include?(ticker.upcase)
        gap = pos_data[:qty] - (imported_qty[ticker.upcase] || 0)
        count += 1 if gap > 0.001
      end
      count
    end

    # Build Trade objects for opening balances
    def build_opening_balance_trades
      return [] unless positions_file_str.present?

      positions = selected_positions
      return [] if positions.empty? || account.nil?

      # Calculate net qty per ticker from ALL trades on this account (existing + just imported)
      net_qty = net_qty_from_account_trades

      # Check for existing opening balance entries to avoid duplicates
      existing_opening_tickers = existing_opening_balance_tickers

      effective_currency = account.currency || family.currency
      opening_trades = []

      positions.each do |ticker, pos_data|
        next if existing_opening_tickers.include?(ticker.upcase)

        gap = pos_data[:qty] - (net_qty[ticker.upcase] || 0)
        next unless gap > 0.001

        security = find_or_create_security(ticker: ticker)
        next unless security

        # Date: 1 day before earliest trade for this security, or 1 day before earliest import row
        earliest_date = earliest_trade_date_for(ticker) || earliest_import_date
        ob_date = earliest_date ? earliest_date - 1.day : Date.current - 1.year

        opening_trades << Trade.new(
          security: security,
          qty: gap,
          price: pos_data[:price],
          currency: effective_currency,
          investment_activity_label: "Buy",
          entry: Entry.new(
            account: account,
            date: ob_date,
            amount: 0,
            name: "Opening balance - #{ticker.upcase}",
            currency: effective_currency,
            notes: "Auto-created from positions CSV",
            import: self,
            import_locked: true
          )
        )
      end

      Rails.logger.info("[FidelityImport] Creating #{opening_trades.size} opening balance trades") if opening_trades.any?
      opening_trades
    end

    # Net qty per ticker from import rows (used in dry_run before import)
    def net_qty_from_rows
      qty_map = Hash.new(0)

      rows.where("entity_type LIKE 'trade:%'").each do |row|
        ticker = row.ticker.to_s.strip.upcase
        next if ticker.blank?

        _entity, activity = row.entity_type.to_s.split(":", 2)
        qty = row.qty.to_d
        qty = qty.abs if activity == "Reinvestment"
        qty = -qty.abs if activity == "Sell" && qty.positive?
        qty_map[ticker] += qty
      end

      qty_map
    end

    # Net qty per ticker from all account trades (used during import!)
    def net_qty_from_account_trades
      return Hash.new(0) if account.nil?

      qty_map = Hash.new(0)
      account.entries
        .where(entryable_type: "Trade")
        .joins("INNER JOIN trades ON trades.id = entries.entryable_id")
        .joins("INNER JOIN securities ON securities.id = trades.security_id")
        .select("securities.ticker, trades.qty")
        .each do |entry|
          qty_map[entry.ticker.upcase] += entry.qty.to_d
        end

      qty_map
    end

    # Tickers that already have opening balance entries on this account
    def existing_opening_balance_tickers
      return Set.new if account.nil?

      tickers = Set.new
      account.entries
        .where("name LIKE ?", "Opening balance%")
        .where(entryable_type: "Trade")
        .joins("INNER JOIN trades ON trades.id = entries.entryable_id")
        .joins("INNER JOIN securities ON securities.id = trades.security_id")
        .select("securities.ticker")
        .each { |e| tickers.add(e.ticker.upcase) }

      tickers
    end

    def earliest_trade_date_for(ticker)
      return nil if account.nil?

      account.entries
        .where(entryable_type: "Trade")
        .joins("INNER JOIN trades ON trades.id = entries.entryable_id")
        .joins("INNER JOIN securities ON securities.id = trades.security_id")
        .where("UPPER(securities.ticker) = ?", ticker.upcase)
        .minimum(:date)
    end

    def earliest_import_date
      dates = rows.filter_map { |r| Date.strptime(r.date, date_format) rescue nil }
      dates.min
    end

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

    # Build a lookup set of existing entries on this account for fast dedup.
    # Key: "date|amount|TICKER" for trades, "date|amount|" for transactions.
    def load_existing_entries
      return Set.new if account.nil?

      date_range = row_date_range
      return Set.new if date_range.nil?

      set = Set.new

      # Load trade entries with security ticker
      account.entries
        .where(date: date_range.first..date_range.last, entryable_type: "Trade")
        .joins("INNER JOIN trades ON trades.id = entries.entryable_id")
        .joins("INNER JOIN securities ON securities.id = trades.security_id")
        .select("entries.date, entries.amount, securities.ticker")
        .each do |entry|
          set.add(dedup_key(entry.date.iso8601, entry.amount, entry.ticker))
        end

      # Load non-trade entries (dividends, fees, transfers)
      account.entries
        .where(date: date_range.first..date_range.last, entryable_type: "Transaction")
        .select(:date, :amount)
        .each do |entry|
          set.add(dedup_key(entry.date.iso8601, entry.amount, nil))
        end

      set
    end

    def row_date_range
      dates = rows.filter_map { |r| Date.strptime(r.date, date_format) rescue nil }
      return nil if dates.empty?
      [dates.min, dates.max]
    end

    def duplicate_entry?(existing_set, date, amount, ticker)
      existing_set.include?(dedup_key(date, amount, ticker))
    end

    def dedup_key(date, amount, ticker)
      # Round to 2 decimal places to avoid float precision issues
      amt = amount.to_d.round(2).to_s
      ticker_part = ticker.present? ? ticker.upcase : ""
      "#{date}|#{amt}|#{ticker_part}"
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
