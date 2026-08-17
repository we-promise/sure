class Assistant::Function::GetValuations < Assistant::Function
  class << self
    def default_page_size
      50
    end

    def name
      "get_valuations"
    end

    def description
      <<~INSTRUCTIONS
        Lists recorded account valuations (reconciliations and anchors), newest first.
        Each entry includes the provenance citation stored in its notes. Use this to
        audit what record_valuation has written, find dates that already carry a
        value, or trace where a balance number came from.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        account_id: {
          type: "string",
          description: "Only valuations for this account UUID (from get_accounts)"
        },
        start_date: {
          type: "string",
          description: "Only valuations on or after this date (YYYY-MM-DD)"
        },
        end_date: {
          type: "string",
          description: "Only valuations on or before this date (YYYY-MM-DD)"
        },
        page: {
          type: "integer",
          description: "Page number (defaults to 1)"
        }
      }
    )
  end

  def call(params = {})
    accessible_ids = user.accessible_accounts.visible.select(:id)
    scope = family.entries
      .where(entryable_type: "Valuation", account_id: accessible_ids)
      .includes(:account, :entryable)

    if params["account_id"].present?
      return error("invalid_account_id", "account_id must be a UUID from get_accounts.") unless valid_uuid?(params["account_id"])

      scope = scope.where(account_id: params["account_id"])
    end

    start_date = parse_date(params["start_date"])
    end_date = parse_date(params["end_date"])
    scope = scope.where(date: start_date..) if start_date
    scope = scope.where(date: ..end_date) if end_date

    ordered = scope.reverse_chronological
    pagy = Pagy.new(count: ordered.count, page: params["page"] || 1, limit: self.class.default_page_size)

    {
      valuations: ordered.offset(pagy.offset).limit(pagy.limit).map { |entry|
        {
          entry_id: entry.id,
          account: { id: entry.account_id, name: entry.account.name, currency: entry.account.currency },
          date: entry.date,
          amount: entry.amount.to_s,
          amount_formatted: entry.amount_money.format,
          kind: entry.entryable.kind,
          notes: entry.notes
        }
      },
      total_results: pagy.count,
      page: pagy.page,
      page_size: self.class.default_page_size,
      total_pages: pagy.pages
    }
  end

  private
    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def error(key, message)
      { error: key, message: message }
    end
end
