# Reads equity grants and their vesting schedules out of a document uploaded
# to a stock plan account, with the PDF-extraction AI route, and stores them on
# the account.
#
# Re-reading a statement replaces the vests that statement created and leaves
# vests from other statements, CSV imports and manual entry alone.
class AccountStatement::EquityGrantReader
  Error = Class.new(StandardError)

  TOOL_NAME = "report_equity_grants".freeze

  SCHEMA = {
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
            strike_price: { type: [ "number", "null" ], description: "Options only: exercise price per share" },
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

  INSTRUCTIONS = <<~TEXT.freeze
    You read equity compensation documents: grant agreements, award summaries, vesting schedules
    and release confirmations for RSUs and stock options.
    Report every grant in the document with every vest you can see, past and future, in units.
    Include withheld units and net proceeds only when the document shows them for that vest.
    Dates in YYYY-MM-DD. Use null for anything you cannot read; never guess or extrapolate a schedule
    that the document does not show.
  TEXT

  attr_reader :statement, :user

  def initialize(statement, user: nil)
    @statement = statement
    @user = user
  end

  # Whether the family (and user, for consent) may send a document to the
  # PDF-extraction route.
  def self.available?(family:, user:)
    Ai.available?(:extract_pdf, family: family, user: user)
  end

  def read!
    raise Error, I18n.t("account_statements.equity_grant_reader.no_account") unless account&.investment&.stock_plan?
    raise Error, I18n.t("account_statements.equity_grant_reader.not_pdf") unless statement.content_type == "application/pdf"

    availability = Ai.availability(:extract_pdf, family: statement.family, user: user)
    raise Error, availability.message_for(user) unless availability.available?

    provider = Provider::Registry.preferred_llm_provider
    raise Error, Ai::Availability.unavailable(:extract_pdf, :not_configured).message_for(user) unless provider.respond_to?(:extract_document_data)

    response = provider.extract_document_data(
      pdf_content: statement.original_file.download,
      tool_name: TOOL_NAME,
      schema: SCHEMA,
      instructions: INSTRUCTIONS,
      family: statement.family
    )
    raise Error, response.error&.message.to_s unless response.success?

    data = response.data
    unless data.is_a?(Hash) && data["grants"].is_a?(Array)
      raise Error, I18n.t("account_statements.equity_grant_reader.unreadable")
    end

    store(data["grants"])
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end

  private
    def account
      statement.account
    end

    def store(grants)
      count = 0
      account.with_lock do
        EquityVest.where(equity_grant: account.equity_grants, account_statement: statement, source: "statement").delete_all
        retained_ids = []
        grants.each do |row|
          next unless row.is_a?(Hash) && row["ticker"].present?

          grant = find_or_build_grant(row)
          grant.update!(
            ticker: row["ticker"],
            grant_type: EquityGrant::GRANT_TYPES.include?(row["grant_type"]) ? row["grant_type"] : "rsu",
            grant_date: parse_date(row["grant_date"]) || grant.grant_date,
            total_units: positive(row["total_units"]) || grant.total_units,
            strike_price: positive(row["strike_price"]) || grant.strike_price,
            source: grant.new_record? ? "statement" : grant.source,
            account_statement: grant.account_statement || statement
          )
          Array(row["vests"]).each { |vest| upsert_vest(grant, vest) if vest.is_a?(Hash) }
          retained_ids << grant.id
          count += 1
        end
        account.equity_grants.where(account_statement: statement, source: "statement").where.not(id: retained_ids).find_each do |grant|
          grant.destroy! if grant.vests.empty?
        end
        statement.update_columns(equity_grants_read_at: Time.current)
      end
      count
    end

    def find_or_build_grant(row)
      identifier = row["grant_identifier"].to_s.strip.presence
      if identifier
        account.equity_grants.find_or_initialize_by(grant_identifier: identifier)
      else
        account.equity_grants.find_or_initialize_by(grant_identifier: nil, ticker: row["ticker"].to_s.strip.upcase, grant_date: parse_date(row["grant_date"]))
      end
    end

    # A vest another statement, a CSV or the user created is left as it is.
    def upsert_vest(grant, row)
      date = parse_date(row["vest_date"])
      units = positive(row["units"])
      return if date.nil? || units.nil?

      vest = grant.vests.find_or_initialize_by(vest_date: date)
      return if vest.persisted? && !(vest.from_statement? && vest.account_statement_id == statement.id)

      vest.update!(
        units: units,
        units_withheld: non_negative(row["units_withheld"]) || vest.units_withheld,
        net_proceeds: non_negative(row["net_proceeds"]) || vest.net_proceeds,
        source: "statement",
        account_statement: statement
      )
    end

    def positive(value)
      number = value.to_d if value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+(\.\d+)?\z/)
      number if number&.positive?
    end

    def non_negative(value)
      number = value.to_d if value.is_a?(Numeric) || value.to_s.match?(/\A\d+(\.\d+)?\z/)
      number if number && !number.negative?
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
end
