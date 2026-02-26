class QifImport < Import
  after_create :set_default_config

  # Parses the stored QIF content and creates Import::Row records.
  # Overrides the base CSV-based method with QIF-specific parsing.
  def generate_rows_from_csv
    rows.destroy_all

    if investment_account?
      generate_investment_rows
    else
      generate_transaction_rows
    end

    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      if investment_account?
        import_investment_rows!
      else
        import_transaction_rows!

        if (ob = QifParser.parse_opening_balance(raw_file_str))
          Account::OpeningBalanceManager.new(account).set_opening_balance(
            balance: ob[:amount],
            date:    ob[:date]
          )
        else
          adjust_opening_anchor_if_needed!
        end
      end
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
    if qif_account_type == "Invst"
      %i[date ticker qty price amount currency name]
    else
      %i[date amount name currency category tags notes]
    end
  end

  def publishable?
    account.present? && super
  end

  # Returns true if import! will move the opening anchor back to cover transactions
  # that predate the current anchor date. Used to show a notice in the confirm step.
  def will_adjust_opening_anchor?
    return false if investment_account?
    return false if QifParser.parse_opening_balance(raw_file_str).present?
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

  # Unique categories used across all rows (blank entries excluded).
  def row_categories
    rows.distinct.pluck(:category).reject(&:blank?).sort
  end

  # Unique tags used across all rows (blank entries excluded).
  def row_tags
    rows.flat_map(&:tags_list).uniq.reject(&:blank?).sort
  end

  # True once the category/tag selection step has been completed
  # (sync_mappings has been called, which always produces at least one mapping).
  def categories_selected?
    mappings.any?
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::TagMapping ]
  end

  private

    def investment_account?
      qif_account_type == "Invst"
    end

    # ------------------------------------------------------------------
    # Row generation
    # ------------------------------------------------------------------

    def generate_transaction_rows
      transactions = QifParser.parse(raw_file_str)

      mapped_rows = transactions.map do |trn|
        {
          date:                   trn.date.to_s,
          amount:                 trn.amount.to_s,
          currency:               default_currency.to_s,
          name:                   (trn.payee.presence || default_row_name).to_s,
          notes:                  trn.memo.to_s,
          category:               trn.category.to_s,
          tags:                   trn.tags.join("|"),
          account:                "",
          qty:                    "",
          ticker:                 "",
          price:                  "",
          exchange_operating_mic: "",
          entity_type:            ""
        }
      end

      if mapped_rows.any?
        rows.insert_all!(mapped_rows)
        rows.reset
      end
    end

    def generate_investment_rows
      inv_transactions = QifParser.parse_investment_transactions(raw_file_str)

      mapped_rows = inv_transactions.map do |trn|
        if QifParser::TRADE_ACTIONS.include?(trn.action)
          qty = trade_qty_for(trn.action, trn.qty)

          {
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
            account:                "",
            exchange_operating_mic: "",
            entity_type:            trn.action
          }
        else
          {
            date:                   trn.date.to_s,
            amount:                 trn.amount.to_s,
            currency:               default_currency.to_s,
            name:                   transaction_row_name(trn),
            notes:                  trn.memo.to_s,
            category:               trn.category.to_s,
            tags:                   trn.tags.join("|"),
            account:                "",
            qty:                    "",
            ticker:                 "",
            price:                  "",
            exchange_operating_mic: "",
            entity_type:            trn.action
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
      transactions = rows.map do |row|
        category = mappings.categories.mappable_for(row.category)
        tags     = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        Transaction.new(
          category: category,
          tags:     tags,
          entry:    Entry.new(
            account:      account,
            date:         row.date_iso,
            amount:       row.signed_amount,
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

    def import_investment_rows!
      trade_rows       = rows.select { |r| QifParser::TRADE_ACTIONS.include?(r.entity_type) }
      transaction_rows = rows.reject { |r| QifParser::TRADE_ACTIONS.include?(r.entity_type) }

      if trade_rows.any?
        trades = trade_rows.map do |row|
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
              account:      account,
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
          # Inflow actions: money entering account → negative Entry.amount
          # Outflow actions: money leaving account → positive Entry.amount
          entry_amount = QifParser::INFLOW_TRANSACTION_ACTIONS.include?(row.entity_type) ? -row.amount.to_d : row.amount.to_d

          category = mappings.categories.mappable_for(row.category)
          tags     = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

          Transaction.new(
            category: category,
            tags:     tags,
            entry:    Entry.new(
              account:      account,
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

    def adjust_opening_anchor_if_needed!
      manager = Account::OpeningBalanceManager.new(account)
      return unless manager.has_opening_anchor?

      earliest = earliest_row_date
      return unless earliest.present? && earliest < manager.opening_date

      Account::OpeningBalanceManager.new(account).set_opening_balance(
        balance: manager.opening_balance,
        date:    earliest - 1.day
      )
    end

    def earliest_row_date
      str = rows.minimum(:date)
      Date.parse(str) if str.present?
    end

    def set_default_config
      update!(
        signage_convention: "inflows_positive",
        date_format:        "%Y-%m-%d",
        number_format:      "1,234.56"
      )
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
