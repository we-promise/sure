# Reads contributions or equity grants out of an uploaded statement PDF with
# the family's AI provider, and stores them on the statement's account.
#
# Re-reading a statement replaces what an earlier read of the same statement
# created, so running it twice never doubles anything.
class AccountStatement::InvestmentDataReader
  Error = Class.new(StandardError)

  KINDS = %w[contributions equity_grants].freeze

  attr_reader :statement, :kind

  def initialize(statement, kind:)
    raise ArgumentError, "unknown kind #{kind}" unless KINDS.include?(kind.to_s)

    @statement = statement
    @kind = kind.to_s
  end

  def self.provider
    provider = Provider::Registry.preferred_llm_provider
    provider if provider.respond_to?(:extract_document_data)
  end

  def self.available?
    provider.present?
  end

  def read!
    raise Error, I18n.t("account_statements.investment_reader.no_account") unless account
    raise Error, I18n.t("account_statements.investment_reader.not_pdf") unless statement.content_type == "application/pdf"

    provider = self.class.provider
    raise Error, I18n.t("account_statements.investment_reader.no_provider") unless provider

    response = provider.extract_document_data(
      pdf_content: statement.original_file.download,
      tool_name: kind == "contributions" ? "report_contributions" : "report_equity_grants",
      schema: kind == "contributions" ? CONTRIBUTIONS_SCHEMA : GRANTS_SCHEMA,
      instructions: kind == "contributions" ? CONTRIBUTIONS_INSTRUCTIONS : GRANTS_INSTRUCTIONS,
      family: statement.family
    )
    raise Error, response.error&.message.to_s unless response.success?

    kind == "contributions" ? store_contributions(response.data) : store_grants(response.data)
  end

  CONTRIBUTIONS_SCHEMA = {
    type: "object",
    properties: {
      contributions: {
        type: "array",
        items: {
          type: "object",
          properties: {
            date: { type: "string", description: "YYYY-MM-DD. For a summary-only statement, the last day of the period." },
            amount: { type: "number", description: "Positive for money put in, negative for money taken out." },
            kind: { type: "string", enum: AccountContribution::KINDS },
            description: { type: [ "string", "null" ] }
          },
          required: %w[date amount kind],
          additionalProperties: false
        }
      }
    },
    required: [ "contributions" ],
    additionalProperties: false
  }.freeze

  CONTRIBUTIONS_INSTRUCTIONS = <<~TEXT.freeze
    You read investment and retirement account statements (401(k), IRA, HSA, brokerage).
    Report only money that entered or left the account from outside it:
      - contribution: the account holder's own contributions or deposits
      - employer_contribution: employer match or profit sharing
      - rollover: money rolled over from another retirement plan
      - transfer_in / transfer_out: transfers to or from other accounts (ACATS, journals between accounts)
      - withdrawal: distributions, withdrawals, loans taken
    Do NOT report trades, dividends, interest, reinvestments, fees, exchanges between funds inside the
    account, or changes in market value.
    When the statement only shows period totals (e.g. "Employee Contributions $5,000.00"), report one
    row per total, dated the last day of the period. Use null for anything you cannot read; never guess.
  TEXT

  GRANTS_SCHEMA = {
    type: "object",
    properties: {
      grants: {
        type: "array",
        items: {
          type: "object",
          properties: {
            grant_identifier: { type: [ "string", "null" ], description: "The grant or award ID" },
            ticker: { type: "string", description: "Stock ticker symbol, e.g. ACME" },
            grant_type: { type: "string", enum: EquityGrant::GRANT_TYPES },
            grant_date: { type: [ "string", "null" ], description: "YYYY-MM-DD" },
            total_units: { type: [ "number", "null" ] },
            vests: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  vest_date: { type: "string", description: "YYYY-MM-DD" },
                  units: { type: "number" },
                  units_withheld: { type: [ "number", "null" ], description: "Shares withheld or sold for taxes" },
                  net_proceeds: { type: [ "number", "null" ], description: "Cash received after taxes, if shown" }
                },
                required: %w[vest_date units],
                additionalProperties: false
              }
            }
          },
          required: %w[ticker grant_type vests],
          additionalProperties: false
        }
      }
    },
    required: [ "grants" ],
    additionalProperties: false
  }.freeze

  GRANTS_INSTRUCTIONS = <<~TEXT.freeze
    You read equity compensation documents: grant agreements, award summaries, vesting schedules
    and release confirmations for RSUs and stock options.
    Report every grant in the document with every vest you can see, past and future, in units.
    Include withheld units and net proceeds only when the document shows them for that vest.
    Dates in YYYY-MM-DD. Use null for anything you cannot read; never guess or extrapolate a schedule
    that the document does not show.
  TEXT

  private
    def account
      statement.account
    end

    def store_contributions(data)
      rows = Array(data["contributions"]).filter_map { |row| contribution_attributes(row) }

      AccountContribution.transaction do
        account.account_contributions.where(account_statement: statement).delete_all
        rows.each { |attrs| account.account_contributions.create!(attrs) }
      end
      rows.size
    end

    def contribution_attributes(row)
      date = parse_date(row["date"])
      amount = row["amount"].to_d if row["amount"].present?
      return nil if date.nil? || amount.nil? || amount.zero?

      kind = AccountContribution::KINDS.include?(row["kind"]) ? row["kind"] : (amount.negative? ? "withdrawal" : "contribution")
      { date: date, amount: amount, kind: kind, description: row["description"].to_s.first(255).presence,
        source: "statement", account_statement: statement, currency: account.currency }
    end

    def store_grants(data)
      count = 0
      EquityGrant.transaction do
        Array(data["grants"]).each do |row|
          next if row["ticker"].blank?

          grant = find_or_build_grant(row)
          grant.update!(
            ticker: row["ticker"],
            grant_type: EquityGrant::GRANT_TYPES.include?(row["grant_type"]) ? row["grant_type"] : "rsu",
            grant_date: parse_date(row["grant_date"]) || grant.grant_date,
            total_units: row["total_units"].presence || grant.total_units,
            source: grant.source.presence || "statement",
            account_statement: grant.account_statement || statement
          )
          Array(row["vests"]).each { |vest| upsert_vest(grant, vest) }
          count += 1
        end
      end
      count
    end

    def find_or_build_grant(row)
      if row["grant_identifier"].present?
        account.equity_grants.find_or_initialize_by(grant_identifier: row["grant_identifier"].to_s.strip)
      else
        account.equity_grants.find_or_initialize_by(ticker: row["ticker"].to_s.upcase, grant_date: parse_date(row["grant_date"]))
      end
    end

    def upsert_vest(grant, row)
      date = parse_date(row["vest_date"])
      units = row["units"].to_d if row["units"].present?
      return if date.nil? || units.nil? || units <= 0

      vest = grant.vests.find_or_initialize_by(vest_date: date)
      vest.update!(
        units: units,
        units_withheld: row["units_withheld"].presence || vest.units_withheld,
        net_proceeds: row["net_proceeds"].presence || vest.net_proceeds,
        source: vest.source.presence || "statement"
      )
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
end
