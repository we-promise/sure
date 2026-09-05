class QifImport < Import
  after_create :set_default_config

  # The date format used to parse the raw QIF file's D-fields (e.g. "%m/%d/%Y").
  # Stored in column_mappings so it doesn't conflict with date_format, which is
  # always "%Y-%m-%d" because QIF rows store dates in ISO 8601 after parsing.
  def qif_date_format
    column_mappings&.dig("qif_date_format") || "%m/%d/%Y"
  end

  def qif_date_format=(fmt)
    self.column_mappings = (column_mappings || {}).merge("qif_date_format" => fmt)
  end

  # Parses the stored QIF content and creates Import::Row records.
  # Overrides the base CSV-based method with QIF-specific parsing.
  #
  # On first run (qif_date_format not yet set), auto-detects the date format
  # from the QIF file's D-field samples.
  def generate_rows_from_csv
    detect_and_set_qif_date_format! unless column_mappings&.key?("qif_date_format")

    rows.destroy_all

    generate_transaction_rows
    generate_investment_rows

    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      import_transaction_rows!
      import_investment_rows!

      apply_opening_balances_or_adjust_anchors!
    end
  end

  # QIF has a fixed format – no CSV column mapping step needed.
  def requires_csv_workflow?
    false
  end

  def rows_ordered
    rows.order(date: :desc, id: :desc)
  end

  def column_keys
    if qif_account_type == "Invst" && has_qif_accounts?
      %i[date account ticker qty price amount currency name]
    elsif qif_account_type == "Invst"
      %i[date ticker qty price amount currency name]
    elsif has_qif_accounts?
      %i[date account amount name currency category tags notes]
    else
      %i[date amount name currency category tags notes]
    end
  end

  def publishable?
    (account.present? || has_qif_accounts?) && super
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    (account.present? || has_qif_accounts?) && super
  end

  # Returns true if import! will move the opening anchor back to cover transactions
  # that predate the current anchor date. Used to show a notice in the confirm step.
  def will_adjust_opening_anchor?
    return false if investment_account?
    return false if QifParser.parse_opening_balance(raw_file_str, date_format: qif_date_format).present?
    return false unless account.present?

    manager = Account::OpeningBalanceManager.new(account)
    return false unless manager.has_opening_anchor?

    earliest = earliest_row_date
    earliest.present? && earliest < manager.opening_date
  end

  # The date the opening anchor will be moved to when will_adjust_opening_anchor? is true.
  def adjusted_opening_anchor_date
    earliest = earliest_row_date
    (earliest - 1.day) if earliest.present?
  end

  # The account type declared in the QIF file (e.g. "CCard", "Bank", "Invst").
  def qif_account_type
    return @qif_account_type if instance_variable_defined?(:@qif_account_type)
    @qif_account_type = raw_file_str.present? ? QifParser.account_type(raw_file_str) : nil
  end

  def qif_accounts
    @qif_accounts ||= raw_file_str.present? ? QifParser.parse_accounts(raw_file_str) : []
  end

  def has_qif_accounts?
    qif_accounts.any?
  end

  # Unique categories used across all rows (blank entries excluded).
  def row_categories
    (rows.distinct.pluck(:category) + selected_split_categories).reject(&:blank?).uniq.sort
  end

  # Returns true if the QIF file contains any split transactions.
  def has_split_transactions?
    return @has_split_transactions if defined?(@has_split_transactions)
    @has_split_transactions = parsed_transactions_with_splits.any?(&:split)
  end

  # Categories that appear on split transactions in the QIF file.
  def split_categories
    return @split_categories if defined?(@split_categories)

    @split_categories = parsed_split_categories
  end

  # Unique tags used across all rows (blank entries excluded).
  def row_tags
    (rows.flat_map(&:tags_list) + selected_split_tags).uniq.reject(&:blank?).sort
  end

  # True once the category/tag selection step has been completed
  # (sync_mappings has been called, which always produces at least one mapping).
  def categories_selected?
    mappings.any?
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::TagMapping ]
  end

  # QIF dates need normalization (apostrophe → separator, 2-digit year expansion)
  # before strptime can parse them, so we delegate to QifParser.
  def raw_date_samples
    QifParser.extract_raw_dates(raw_file_str)
  end

  def try_parse_date_sample(sample, format:)
    QifParser.try_parse_date(sample, date_format: format)
  end

  private

    def parsed_transactions_with_splits
      @parsed_transactions_with_splits ||= QifParser.parse(raw_file_str, date_format: qif_date_format)
    end

    def parsed_transaction_by_source_row_number
      @parsed_transaction_by_source_row_number ||= parsed_transactions_with_splits.each.with_index(1).to_h { |trn, index| [ index, trn ] }
    end

    def parsed_split_categories
      parsed_transactions_with_splits.flat_map { |trn| trn.split_lines.to_a.map(&:category) }.reject(&:blank?).uniq.sort
    end

    def parsed_split_tags
      parsed_transactions_with_splits.flat_map { |trn| trn.split_lines.to_a.flat_map(&:tags) }
    end

    def selected_split_categories
      selected = column_mappings&.dig("qif_selected_categories")
      return parsed_split_categories unless selected

      parsed_split_categories & selected
    end

    def selected_split_tags
      selected = column_mappings&.dig("qif_selected_tags")
      return parsed_split_tags unless selected

      parsed_split_tags & selected
    end

    def investment_account?
      qif_account_type == "Invst"
    end

    # ------------------------------------------------------------------
    # Row generation
    # ------------------------------------------------------------------

    def generate_transaction_rows
      transactions = QifParser.parse(raw_file_str, date_format: qif_date_format)

      mapped_rows = transactions.map.with_index(1) do |trn, index|
        {
          source_row_number:       index,
          date:                   trn.date.to_s,
          amount:                 trn.amount.to_s,
          currency:               default_currency.to_s,
          name:                   (trn.payee.presence || default_row_name).to_s,
          notes:                  trn.memo.to_s,
          category:               trn.category.to_s,
          tags:                   trn.tags.join("|"),
          account:                trn.account_name.to_s,
          qty:                    "",
          ticker:                 "",
          price:                  "",
          exchange_operating_mic: "",
          entity_type:            "",
          resource_type:          trn.account_type.to_s
        }
      end

      if mapped_rows.any?
        rows.insert_all!(mapped_rows)
        rows.reset
      end
    end

    def generate_investment_rows
      inv_transactions = QifParser.parse_investment_transactions(raw_file_str, date_format: qif_date_format)
      source_row_offset = rows.maximum(:source_row_number).to_i

      mapped_rows = inv_transactions.map.with_index(1) do |trn, index|
        source_row_number = source_row_offset + index

        if QifParser::TRADE_ACTIONS.include?(trn.action)
          qty = trade_qty_for(trn.action, trn.qty)

          {
            source_row_number:       source_row_number,
            date:                   trn.date.to_s,
            ticker:                 trn.security_ticker.to_s,
            qty:                    qty.to_s,
            price:                  trn.price.to_s,
            amount:                 trn.amount.to_s,
            currency:               default_currency.to_s,
            name:                   trade_row_name(trn),
            notes:                  trn.memo.to_s,
            category:               "",
            tags:                   "",
            account:                trn.account_name.to_s,
            exchange_operating_mic: "",
            entity_type:            trn.action,
            resource_type:          trn.account_type.to_s
          }
        else
          {
            source_row_number:       source_row_number,
            date:                   trn.date.to_s,
            amount:                 trn.amount.to_s,
            currency:               default_currency.to_s,
            name:                   transaction_row_name(trn),
            notes:                  trn.memo.to_s,
            category:               trn.category.to_s,
            tags:                   trn.tags.join("|"),
            account:                trn.account_name.to_s,
            qty:                    "",
            ticker:                 "",
            price:                  "",
            exchange_operating_mic: "",
            entity_type:            trn.action,
            resource_type:          trn.account_type.to_s
          }
        end
      end

      if mapped_rows.any?
        rows.insert_all!(mapped_rows)
        rows.reset
      end
    end

    # ------------------------------------------------------------------
    # Import execution
    # ------------------------------------------------------------------

    def import_transaction_rows!
      split_rows, regular_rows = rows.ordered
                                    .reject { |row| row.resource_type == "Invst" }
                                    .partition do |row|
                                      parsed_transaction_by_source_row_number[row.source_row_number]&.split_lines.present?
                                    end

      import_regular_transaction_rows!(regular_rows)
      import_split_transaction_rows!(split_rows)
    end

    def import_regular_transaction_rows!(regular_rows)
      return if regular_rows.empty?

      transactions = regular_rows.map do |row|
        row_account = account_for_row(row)
        category = mappings.categories.mappable_for(row.category)
        tags     = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        Transaction.new(
          category: category,
          tags:     tags,
          entry:    Entry.new(
            account:       row_account,
            date:          row.date_iso,
            amount:        row.signed_amount,
            name:          row.name,
            currency:      row.currency,
            notes:         row.notes,
            import:        self,
            import_locked: true
          )
        )
      end

      Transaction.import!(transactions, recursive: true)
    end

    def import_split_transaction_rows!(split_rows)
      split_rows.each do |row|
        row_account = account_for_row(row)
        parsed_transaction = parsed_transaction_by_source_row_number[row.source_row_number]
        category = mappings.categories.mappable_for(row.category)
        tags     = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        transaction = Transaction.create!(
          category: category,
          tags:     tags
        )

        entry = Entry.create!(
          account:       row_account,
          date:          row.date_iso,
          amount:        row.signed_amount,
          name:          row.name,
          currency:      row.currency,
          notes:         row.notes,
          import:        self,
          import_locked: true,
          entryable:     transaction
        )

        import_split_lines!(entry, parsed_transaction, fallback_tags: tags) if parsed_transaction&.split_lines.present?
      end
    end

    def import_split_lines!(entry, parsed_transaction, fallback_tags:)
      split_rows = parsed_transaction.split_lines.map do |line|
        {
          name:        line.memo.presence || line.category.presence || entry.name,
          amount:      signed_transaction_amount(line.amount),
          category_id: mappings.categories.mappable_for(line.category)&.id,
          notes:       line.memo,
          tags:        line.tags.present? ? line.tags.map { |tag| mappings.tags.mappable_for(tag) }.compact : fallback_tags
        }
      end

      return unless split_rows.sum { |row| row[:amount].to_d } == entry.amount

      children = entry.split!(split_rows)
      children.zip(split_rows).each do |child, row|
        child.update!(notes: row[:notes]) if row[:notes].present?
        row[:tags].each { |tag| child.entryable.taggings.create!(tag: tag) }
      end
    end

    def signed_transaction_amount(amount)
      amount.to_d * (signage_convention == "inflows_positive" ? -1 : 1)
    end

    def import_investment_rows!
      investment_rows  = rows.select { |r| r.resource_type == "Invst" }
      trade_rows       = investment_rows.select { |r| QifParser::TRADE_ACTIONS.include?(r.entity_type) }
      transaction_rows = investment_rows.reject { |r| QifParser::TRADE_ACTIONS.include?(r.entity_type) }

      if trade_rows.any?
        trades = trade_rows.map do |row|
          row_account = account_for_row(row)
          security = find_or_create_security(ticker: row.ticker)

          # Use the stored T-field amount for accuracy (includes any fees/commissions).
          # Buy-like actions are cash outflows (positive); sell-like are inflows (negative).
          entry_amount = QifParser::BUY_LIKE_ACTIONS.include?(row.entity_type) ? row.amount.to_d : -row.amount.to_d

          Trade.new(
            security:                  security,
            qty:                       row.qty.to_d,
            price:                     row.price.to_d,
            currency:                  row.currency,
            investment_activity_label: investment_activity_label_for(row.entity_type),
            entry:                     Entry.new(
              account:      row_account,
              date:         row.date_iso,
              amount:       entry_amount,
              name:         row.name,
              currency:     row.currency,
              import:       self,
              import_locked: true
            )
          )
        end

        Trade.import!(trades, recursive: true)
      end

      if transaction_rows.any?
        transactions = transaction_rows.map do |row|
          row_account = account_for_row(row)
          # Inflow actions: money entering account → negative Entry.amount
          # Outflow actions: money leaving account → positive Entry.amount
          entry_amount = QifParser::INFLOW_TRANSACTION_ACTIONS.include?(row.entity_type) ? -row.amount.to_d : row.amount.to_d

          category = mappings.categories.mappable_for(row.category)
          tags     = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

          Transaction.new(
            category: category,
            tags:     tags,
            entry:    Entry.new(
              account:      row_account,
              date:         row.date_iso,
              amount:       entry_amount,
              name:         row.name,
              currency:     row.currency,
              notes:        row.notes,
              import:       self,
              import_locked: true
            )
          )
        end

        Transaction.import!(transactions, recursive: true)
      end
    end

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def apply_opening_balances_or_adjust_anchors!
      opening_balances = QifParser.parse_opening_balances(raw_file_str, date_format: qif_date_format)

      if has_qif_accounts?
        accounts_by_name = qif_accounts.to_h { |qif_account| [ qif_account.name, find_or_create_qif_account(qif_account.name, qif_account.account_type) ] }
        opening_balances.each do |opening_balance|
          target_account = accounts_by_name[opening_balance[:account_name]]
          next unless target_account

          Account::OpeningBalanceManager.new(target_account).set_opening_balance(
            balance: opening_balance[:amount],
            date:    opening_balance[:date]
          )
        end

        accounts_by_name.each_value do |target_account|
          next if opening_balances.any? { |opening_balance| opening_balance[:account_name] == target_account.name }

          adjust_opening_anchor_if_needed!(target_account, earliest_row_date(target_account.name))
        end
      elsif (opening_balance = opening_balances.first)
        Account::OpeningBalanceManager.new(account).set_opening_balance(
          balance: opening_balance[:amount],
          date:    opening_balance[:date]
        )
      else
        adjust_opening_anchor_if_needed!(account, earliest_row_date)
      end
    end

    def adjust_opening_anchor_if_needed!(target_account, earliest)
      manager = Account::OpeningBalanceManager.new(target_account)
      return unless manager.has_opening_anchor?

      return unless earliest.present? && earliest < manager.opening_date

      Account::OpeningBalanceManager.new(target_account).set_opening_balance(
        balance: manager.opening_balance,
        date:    earliest - 1.day
      )
    end

    def earliest_row_date(account_name = nil)
      scope = account_name.present? ? rows.where(account: account_name) : rows
      str = scope.minimum(:date)
      Date.parse(str) if str.present?
    end

    def account_for_row(row)
      return account if row.account.blank?

      qif_account_cache[row.account] ||= find_or_create_qif_account(row.account, row.resource_type)
    end

    def qif_account_cache
      @qif_account_cache ||= {}
    end

    def find_or_create_qif_account(name, qif_type)
      family.accounts.find_by(name: name) || Account.create_and_sync(
        {
          family: family,
          name: name,
          balance: 0,
          currency: default_currency,
          accountable_type: accountable_type_for_qif_type(qif_type),
          import: self
        },
        skip_initial_sync: true
      )
    end

    def accountable_type_for_qif_type(qif_type)
      case qif_type
      when "CCard"
        "CreditCard"
      when "Invst"
        "Investment"
      when "Oth A"
        "OtherAsset"
      when "Oth L"
        "OtherLiability"
      else
        "Depository"
      end
    end

    def set_default_config
      update!(
        signage_convention: "inflows_positive",
        date_format:        "%Y-%m-%d",
        number_format:      "1,234.56"
      )
    end

    # Auto-detects the QIF file's date format from D-field samples and persists it.
    # Falls back to "%m/%d/%Y" (US convention) if detection is inconclusive.
    def detect_and_set_qif_date_format!
      samples = QifParser.extract_raw_dates(raw_file_str)
      detected = Import.detect_date_format(samples, fallback: "%m/%d/%Y")
      self.qif_date_format = detected
      update_column(:column_mappings, column_mappings)
    end

    # Returns the signed qty for a trade row:
    # buy-like actions keep qty positive; sell-like negate it.
    def trade_qty_for(action, raw_qty)
      qty = raw_qty.to_d
      QifParser::SELL_LIKE_ACTIONS.include?(action) ? -qty : qty
    end

    def investment_activity_label_for(action)
      return nil if action.blank?
      QifParser::BUY_LIKE_ACTIONS.include?(action) ? "Buy" : "Sell"
    end

    def trade_row_name(trn)
      type   = QifParser::BUY_LIKE_ACTIONS.include?(trn.action) ? "buy" : "sell"
      ticker = trn.security_ticker.presence || trn.security_name || "Unknown"
      Trade.build_name(type, trn.qty.to_d.abs, ticker)
    end

    def transaction_row_name(trn)
      security = trn.security_name.presence
      payee    = trn.payee.presence

      case trn.action
      when "Div"     then payee || (security ? "Dividend: #{security}" : "Dividend")
      when "IntInc"  then payee || (security ? "Interest: #{security}" : "Interest")
      when "XIn"     then payee || "Cash Transfer In"
      when "XOut"    then payee || "Cash Transfer Out"
      when "CGLong"  then payee || (security ? "Capital Gain (Long): #{security}" : "Capital Gain (Long)")
      when "CGShort" then payee || (security ? "Capital Gain (Short): #{security}" : "Capital Gain (Short)")
      when "MiscInc" then payee || trn.memo.presence || "Miscellaneous Income"
      when "MiscExp" then payee || trn.memo.presence || "Miscellaneous Expense"
      else                payee || trn.action
      end
    end

    def find_or_create_security(ticker: nil, exchange_operating_mic: nil)
      return nil unless ticker.present?

      @security_cache ||= {}

      cache_key = [ ticker, exchange_operating_mic ].compact.join(":")
      security  = @security_cache[cache_key]
      return security if security.present?

      security = Security::Resolver.new(
        ticker,
        exchange_operating_mic: exchange_operating_mic.presence
      ).resolve

      @security_cache[cache_key] = security
      security
    end
end
