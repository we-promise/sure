# Shared month handling for budget-facing assistant tools so month slugs
# round-trip between get_budget and update_budget, including families with a
# custom month start day.
module Assistant::Function::MonthResolvable
  private
    def resolve_month_start(raw)
      base = parse_month(raw)
      return (base || Date.current).beginning_of_month unless family.uses_custom_month_start?

      # Match Budget.param_to_date for explicit slugs so the input round-trips with the response.
      base ? Date.new(base.year, base.month, family.month_start_day) : family.custom_month_start_for(Date.current)
    end

    def parse_month(raw)
      return nil if raw.blank?

      # Date.strptime ignores trailing characters, so guard with strict anchors first.
      fmt = case raw
      when /\A\d{4}-\d{2}\z/         then "%Y-%m"
      when /\A[A-Za-z]{3}-\d{4}\z/   then "%b-%Y"
      end

      raise Assistant::Error, "Invalid month: #{raw}. Use YYYY-MM or MMM-YYYY." if fmt.nil?

      Date.strptime(raw, fmt)
    rescue ArgumentError
      raise Assistant::Error, "Invalid month: #{raw}. Use YYYY-MM or MMM-YYYY."
    end
end
