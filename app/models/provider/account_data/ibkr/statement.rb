require "digest"

# Flex is one HTTP document, not a paginated API. Keep that boundary explicit:
# archive the original XML once, then identify every slice by its exact digest.
class Provider::AccountData::Ibkr::Statement
  SECTIONS = {
    "position_values" => [ %w[ChangeInPositionValues], %w[ChangeInPositionValue] ],
    "cash_report" => [ %w[CashReport CashReports], %w[CashReport CashReportCurrency CashReportRow] ],
    "equity_summary" => [ %w[EquitySummaryInBase], %w[EquitySummaryByReportDateInBase] ],
    "open_positions" => [ %w[OpenPositions], %w[OpenPosition] ],
    "trades" => [ %w[Trades], %w[Trade] ],
    "cash_transactions" => [ %w[CashTransactions], %w[CashTransaction] ]
  }.freeze
  MAX_BYTES = 32 * 1024 * 1024

  attr_reader :xml, :fingerprint, :accounts

  def initialize(xml, observed_on:)
    unless xml.is_a?(String) && xml.bytesize <= MAX_BYTES && !xml.match?(/<!DOCTYPE/i)
      raise ArgumentError
    end
    @xml = xml.dup.freeze
    @fingerprint = Digest::SHA256.hexdigest(@xml).freeze
    document = Nokogiri::XML(@xml) { |config| config.strict.nonet.noblanks }
    raise ArgumentError unless document.root&.name == "FlexQueryResponse"
    statements = document.root.xpath("./FlexStatements/FlexStatement | ./FlexStatement")
    raise ArgumentError if statements.empty?
    count = document.root.at_xpath("./FlexStatements")&.[]("count")
    raise ArgumentError if count && (!count.match?(/\A\d+\z/) || count.to_i != statements.size)
    @accounts = statements.map { |statement| parse_account(statement, observed_on: observed_on) }
    raise ArgumentError unless @accounts.map { |account| account.fetch("external_id") }.uniq.size == @accounts.size
    deep_freeze(@accounts)
    freeze
  rescue ArgumentError, TypeError, KeyError, Nokogiri::XML::SyntaxError
    raise Provider::AccountData::InvalidResponse, "Invalid or incomplete IBKR Flex XML statement", cause: nil
  end

  private
    def parse_account(statement, observed_on:)
      attributes = node_attributes(statement)
      information = node_attributes(statement.at_xpath("./AccountInformation"))
      id = information["account_id"].presence || attributes["account_id"].presence
      raise ArgumentError unless id
      if information["account_id"].present? && attributes["account_id"].present? && information["account_id"] != attributes["account_id"]
        raise ArgumentError
      end
      data = { "external_id" => id, "currency" => information["currency"].presence&.upcase || "USD", "sections" => [] }
      SECTIONS.each do |key, (containers, rows)|
        nodes = section_nodes(statement, containers, rows)
        data[key] = nodes.map { |node| node_attributes(node) }
        if data[key].any? { |row| row["account_id"].present? && row["account_id"] != id }
          raise ArgumentError
        end
        if (containers + rows).any? { |name| statement.at_xpath("./#{name}") }
          data.fetch("sections") << key
        end
      end
      from = Provider::AccountData::Ibkr::Values.date(attributes.fetch("from_date"))
      through = Provider::AccountData::Ibkr::Values.date(attributes.fetch("to_date"))
      raise ArgumentError if from > through || through > observed_on
      data["from_date"] = from.iso8601
      data["to_date"] = through.iso8601
      report_dates = data.fetch("open_positions").filter_map { |row| date_if_present(row["report_date"]) }
      report_dates = data.fetch("equity_summary").filter_map { |row| date_if_present(row["report_date"]) } if report_dates.empty?
      report_date = report_dates.max || through
      raise ArgumentError if report_date > observed_on
      data["report_date"] = report_date.iso8601
      data
    end

    def section_nodes(statement, containers, rows)
      result = containers.flat_map do |name|
        statement.xpath("./#{name}").flat_map do |container|
          if container.element_children.any?
            container.element_children.select { |child| rows.include?(child.name) }
          elsif rows.include?(container.name) && container.attribute_nodes.any?
            [ container ]
          else
            []
          end
        end
      end
      result = rows.flat_map { |name| statement.xpath("./#{name}").select { |node| node.attribute_nodes.any? } } if result.empty?
      result.uniq
    end

    def node_attributes(node)
      return {} unless node
      node.attribute_nodes.to_h { |attribute| [ attribute.name.underscore, attribute.value ] }
    end

    def date_if_present(value)
      value.present? ? Provider::AccountData::Ibkr::Values.date(value) : nil
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
end
