module Assistant::TokenEstimator
  CHARS_PER_TOKEN = 4
  SAFETY_FACTOR = 1.25

  def self.estimate(value)
    chars = char_length(value)
    ((chars / CHARS_PER_TOKEN.to_f) * SAFETY_FACTOR).ceil
  end

  def self.char_length(value)
    case value
    when nil    then 0
    when String then value.length
    when Array  then value.sum { |v| char_length(v) }
    when Hash   then value.to_json.length
    else value.to_s.length
    end
  end
end
