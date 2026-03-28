class PdfImport < Import
  INVESTMENT_TRADE_ACCOUNTABLE_TYPES = %w[Investment Crypto].freeze

  has_one_attached :pdf_file, dependent: :purge_later

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }, allow_nil: true
  validate :investment_statement_account_must_allow_trades

  def import!
    raise "Account required for PDF import" unless account.present?

    if investment_statement?
      import_trades!
    else
      import_transactions!
    end
  end

  def pdf_uploaded?
    pdf_file.attached?
  end

  def ai_processed?
    ai_summary.present?
  end

  def process_with_ai_later
    ProcessPdfJob.perform_later(self)
  end

  def process_with_ai
    provider = Provider::Registry.get_provider(:openai)
    raise "AI provider not configured" unless provider
    raise "AI provider does not support PDF processing" unless provider.supports_pdf_processing?

    response = provider.process_pdf(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown PDF processing error"
      raise error_message
    end

    result = response.data
    update!(
      ai_summary: result.summary,
      document_type: result.document_type
    )

    result
  end

  def extract_transactions
    return unless statement_with_transactions?

    provider = Provider::Registry.get_provider(:openai)
    raise "AI provider not configured" unless provider

    response = provider.extract_bank_statement(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown extraction error"
      raise error_message
    end

    update!(extracted_data: response.data)
    response.data
  end

  def extract_trades
    return unless investment_statement?

    provider = Provider::Registry.get_provider(:openai)
    raise "AI provider not configured" unless provider

    response = provider.extract_brokerage_statement(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown extraction error"
      raise error_message
    end

    update!(extracted_data: response.data)
    response.data
  end

  def bank_statement?
    document_type == "bank_statement"
  end

  def investment_statement?
    document_type == "investment_statement"
  end

  def statement_with_transactions?
    document_type.in?(%w[bank_statement credit_card_statement])
  end

  def statement_with_extractable_data?
    statement_with_transactions? || investment_statement?
  end

  def has_extracted_transactions?
    extracted_data.present? && extracted_data["transactions"].present?
  end

  def has_extracted_trades?
    extracted_data.present? && extracted_data["trades"].present?
  end

  def has_extracted_data?
    has_extracted_transactions? || has_extracted_trades?
  end

  def extracted_transactions
    extracted_data&.dig("transactions") || []
  end

  def extracted_trades
    extracted_data&.dig("trades") || []
  end

  def generate_rows_from_extracted_data
    if investment_statement?
      generate_rows_from_extracted_trades
    else
      generate_rows_from_extracted_transactions
    end
  end

  def send_next_steps_email(user)
    PdfImportMailer.with(
      user: user,
      pdf_import: self
    ).next_steps.deliver_later
  end

  def uploaded?
    pdf_uploaded?
  end

  def configured?
    ai_processed? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    return false unless account.present? && cleaned? && mappings.all?(&:valid?)

    return false unless statement_with_transactions? || investment_statement?
    return false if investment_statement? && !account_investment_trade_eligible?

    true
  end

  def column_keys
    if investment_statement?
      %i[date ticker qty price fee name]
    else
      %i[date amount name category notes]
    end
  end

  def requires_csv_workflow?
    false
  end

  def pdf_file_content
    return nil unless pdf_file.attached?

    pdf_file.download
  end

  def required_column_keys
    if investment_statement?
      %i[date ticker qty price]
    else
      %i[date amount]
    end
  end

  def mapping_steps
    base = []
    unless investment_statement?
      base << Import::CategoryMapping if rows.where.not(category: [ nil, "" ]).exists?
    end
    base
  end

  private

    def account_investment_trade_eligible?
      account.accountable_type.in?(INVESTMENT_TRADE_ACCOUNTABLE_TYPES)
    end

    def investment_statement_account_must_allow_trades
      return unless investment_statement?
      return if account.nil?

      unless account_investment_trade_eligible?
        errors.add(:account, I18n.t("imports.errors.investment_statement_account_type"))
      end
    end

    def import_transactions!
      transaction do
        mappings.each(&:create_mappable!)

        new_transactions = rows.map do |row|
          category = mappings.categories.mappable_for(row.category)

          Transaction.new(
            category: category,
            entry: Entry.new(
              account: account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: row.currency,
              notes: row.notes,
              import: self,
              import_locked: true
            )
          )
        end

        Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
      end
    end

    def import_trades!
      transaction do
        trades = rows.map do |row|
          security = find_or_create_security(
            ticker: row.ticker,
            exchange_operating_mic: row.exchange_operating_mic
          )

          Trade.new(
            security: security,
            qty: row.qty,
            currency: row.currency.presence || account.currency,
            price: row.price,
            fee: row.fee.present? ? row.fee.to_d : 0,
            investment_activity_label: investment_activity_label_for(row.qty),
            entry: Entry.new(
              account: account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: trade_entry_name_for(row),
              currency: row.currency.presence || account.currency,
              import: self,
              import_locked: true
            )
          )
        end

        Trade.import!(trades, recursive: true) if trades.any?
      end
    end

    def investment_activity_label_for(qty)
      return nil if qty.blank? || qty.to_d.zero?
      qty.to_d.positive? ? "Buy" : "Sell"
    end

    def trade_entry_name_for(row)
      return row.name if row.name.present?

      qty_d = row.qty.to_d
      if row.qty.blank? || qty_d.zero?
        ticker = row.ticker.to_s.strip
        ticker.present? ? "Trade #{ticker}" : "Imported trade"
      else
        Trade.build_name(qty_d.positive? ? "buy" : "sell", row.qty, row.ticker)
      end
    end

    def find_or_create_security(ticker: nil, exchange_operating_mic: nil)
      return nil unless ticker.present?

      @security_cache ||= {}
      cache_key = [ ticker, exchange_operating_mic ].compact.join(":")

      return @security_cache[cache_key] if @security_cache.key?(cache_key)

      security = Security::Resolver.new(
        ticker,
        exchange_operating_mic: exchange_operating_mic.presence
      ).resolve

      @security_cache[cache_key] = security
      security
    end

    def generate_rows_from_extracted_transactions
      transaction do
        rows.destroy_all

        unless has_extracted_transactions?
          update_column(:rows_count, 0)
          return
        end

        currency = account&.currency || family.currency

        mapped_rows = extracted_transactions.map do |txn|
          {
            import_id: id,
            date: format_date_for_import(txn["date"]),
            amount: txn["amount"].to_s,
            name: txn["name"].to_s,
            category: txn["category"].to_s,
            notes: txn["notes"].to_s,
            currency: currency
          }
        end

        Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
        update_column(:rows_count, mapped_rows.size)
      end
    end

    def generate_rows_from_extracted_trades
      transaction do
        rows.destroy_all

        unless has_extracted_trades?
          update_column(:rows_count, 0)
          return
        end

        currency = extracted_data["currency"] || account&.currency || family.currency

        mapped_rows = extracted_trades.map do |trade|
          {
            import_id: id,
            date: format_date_for_import(trade["date"]),
            ticker: trade["ticker"].to_s,
            qty: trade["qty"].to_s,
            price: trade["price"].to_s,
            fee: trade["fees"].to_s,
            name: trade["name"].to_s,
            currency: trade["currency"].presence || currency,
            exchange_operating_mic: trade["exchange_operating_mic"].to_s
          }
        end

        Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
        update_column(:rows_count, mapped_rows.size)
      end
    end

    def format_date_for_import(date_str)
      return "" if date_str.blank?

      Date.parse(date_str).strftime(date_format)
    rescue ArgumentError
      date_str.to_s
    end
end
