class IbkrItem::ReportParser
  include IbkrAccount::DataHelpers

  class ParseError < StandardError; end

  POSITION_VALUE_CONTAINER_NAMES = %w[ChangeInPositionValues].freeze
  POSITION_VALUE_ROW_NAMES = %w[ChangeInPositionValue].freeze
  CASH_REPORT_CONTAINER_NAMES = %w[CashReport CashReports].freeze
  CASH_REPORT_ROW_NAMES = %w[CashReport CashReportCurrency CashReportRow].freeze
  EQUITY_SUMMARY_CONTAINER_NAMES = %w[EquitySummaryInBase].freeze
  EQUITY_SUMMARY_ROW_NAMES = %w[EquitySummaryByReportDateInBase].freeze
  OPEN_POSITION_CONTAINER_NAMES = %w[OpenPositions].freeze
  OPEN_POSITION_ROW_NAMES = %w[OpenPosition].freeze
  TRADES_CONTAINER_NAMES = %w[Trades].freeze
  TRADE_ROW_NAMES = %w[Trade].freeze
  CASH_TRANSACTION_CONTAINER_NAMES = %w[CashTransactions].freeze
  CASH_TRANSACTION_ROW_NAMES = %w[CashTransaction].freeze

  def initialize(xml_body)
    @document = Nokogiri::XML(xml_body.to_s) { |config| config.strict.noblanks }
  rescue Nokogiri::XML::SyntaxError => e
    raise ParseError, "Invalid IBKR Flex XML: #{e.message}"
  end

  def parse
    validate_document!

    {
      metadata: root_metadata,
      accounts: flex_statements.map { |statement| parse_statement(statement) }
    }
  end

  private

    def validate_document!
      raise ParseError, "Invalid IBKR Flex XML: missing FlexQueryResponse root." unless @document.at_xpath("//FlexQueryResponse")
      raise ParseError, "Invalid IBKR Flex XML: no FlexStatement nodes found." if flex_statements.empty?
    end

    def flex_statements
      @document.xpath("//FlexStatement")
    end

    def root_metadata
      node_attributes(@document.at_xpath("//FlexQueryResponse"))
    end

    def parse_statement(statement)
      statement_data = node_attributes(statement)
      account_information = node_attributes(statement.at_xpath("./AccountInformation"))
      position_values = section_rows(statement, POSITION_VALUE_CONTAINER_NAMES, POSITION_VALUE_ROW_NAMES)
      cash_report = section_rows(statement, CASH_REPORT_CONTAINER_NAMES, CASH_REPORT_ROW_NAMES)
      equity_summary_in_base = section_rows(statement, EQUITY_SUMMARY_CONTAINER_NAMES, EQUITY_SUMMARY_ROW_NAMES)
      open_positions = section_rows(statement, OPEN_POSITION_CONTAINER_NAMES, OPEN_POSITION_ROW_NAMES)
      trades = section_rows(statement, TRADES_CONTAINER_NAMES, TRADE_ROW_NAMES)
      cash_transactions = section_rows(statement, CASH_TRANSACTION_CONTAINER_NAMES, CASH_TRANSACTION_ROW_NAMES)
      account_id = account_information["account_id"].presence || statement_data["account_id"]

      raise ParseError, "Invalid IBKR Flex XML: missing account identifier in FlexStatement." if account_id.blank?

      currency = account_information["currency"].presence&.upcase || "USD"
      report_date = open_positions.filter_map { |row| parse_date(row["report_date"]) }.max ||
        equity_summary_in_base.filter_map { |row| parse_date(row["report_date"]) }.max ||
        parse_date(statement_data["to_date"]) ||
        Date.current

      {
        ibkr_account_id: account_id,
        name: account_id,
        currency: currency,
        cash_balance: extract_cash_balance(cash_report, currency),
        current_balance: extract_total_balance(position_values, cash_report, currency),
        report_date: report_date,
        statement: statement_data,
        cash_report: cash_report,
        equity_summary_in_base: equity_summary_in_base,
        open_positions: open_positions,
        trades: trades,
        cash_transactions: cash_transactions,
        raw_payload: {
          statement: statement_data,
          cash_report: cash_report,
          equity_summary_in_base: equity_summary_in_base,
          open_positions: open_positions,
          trades: trades,
          cash_transactions: cash_transactions
        }
      }
    end

    def section_rows(statement, container_names, row_names)
      rows = []

      container_names.each do |container_name|
        statement.xpath("./#{container_name}").each do |container|
          children = container.element_children

          if children.any?
            rows.concat(children.select { |child| row_names.include?(child.name) })
          elsif row_names.include?(container.name)
            rows << container
          end
        end
      end

      if rows.empty?
        row_names.each do |row_name|
          rows.concat(statement.xpath("./#{row_name}"))
        end
      end

      rows.map { |row| node_attributes(row) }.reject(&:blank?)
    end

    def node_attributes(node)
      return {} unless node

      node.attribute_nodes.each_with_object({}) do |attribute, result|
        result[attribute.name.underscore] = attribute.value
      end
    end

    def extract_cash_balance(cash_rows, account_currency)
      base_summary = cash_rows.find { |row| row["currency"] == "BASE_SUMMARY" }
      account_row = cash_rows.find { |row| row["currency"] == account_currency }
      row = base_summary || account_row

      parse_decimal(row&.fetch("ending_cash", nil)) || BigDecimal("0")
    end

    def extract_current_balance(position_values, account_currency)
      base_summary = position_values.find { |row| row["currency"] == "BASE_SUMMARY" }
      account_row = position_values.find { |row| row["currency"] == account_currency }
      row = base_summary || account_row

      parse_decimal(row&.fetch("end_of_period_value", nil)) || BigDecimal("0")
    end

    def extract_total_balance(position_values, cash_rows, account_currency)
      extract_current_balance(position_values, account_currency) + extract_cash_balance(cash_rows, account_currency)
    end
end
