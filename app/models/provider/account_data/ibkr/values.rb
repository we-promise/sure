require "bigdecimal"
require "date"

# Flex exports use decimal strings (including accounting parentheses) and local
# report dates. Neither should pass through floating point or ambient Time.zone.
module Provider::AccountData::Ibkr::Values
  def self.decimal(value)
    return value if value.is_a?(BigDecimal) && value.finite?
    return BigDecimal(value.to_s) if value.is_a?(Integer)
    raise ArgumentError unless value.is_a?(String)
    normalized = value.strip
    normalized = "-#{normalized[1..-2]}" if normalized.start_with?("(") && normalized.end_with?(")")
    unless normalized.match?(/\A[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?\z/)
      raise ArgumentError
    end
    BigDecimal(normalized.delete(","))
  end

  def self.date(value)
    return value if value.instance_of?(Date)
    raise ArgumentError unless value.is_a?(String)
    match = /\A(\d{4}-\d{2}-\d{2}|\d{8})(?:[; T](\d{2}):?(\d{2}):?(\d{2})(?:\.\d+)?)?\z/.match(value)
    raise ArgumentError unless match
    if match[2] && !(match[2].to_i <= 23 && match[3].to_i <= 59 && match[4].to_i <= 59)
      raise ArgumentError
    end
    match[1].include?("-") ? Date.iso8601(match[1]) : Date.strptime(match[1], "%Y%m%d")
  end
end
