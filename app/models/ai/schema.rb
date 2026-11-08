# Coerces a model's parsed JSON against a generation's schema (Ai::Generation's step 3), so feature
# code gets one shape whatever the model or JSON mode produced:
#
# - "null", "" and missing values become nil;
# - numbers in strings become numbers; integers expected as strings become strings;
# - a value outside an `enum`, or outside `minimum`/`maximum`, becomes nil, unless the generation
#   matches that field itself (`match:`, such as categorize's fuzzy category names);
# - field names models use instead of the schema's are mapped (`aliases:`, today's
#   TRANSACTION_ID_KEYS and the rest), and so is a top-level array or another wrapper key
#   (`{"results": [...]}`), as today's parsers accept;
# - array items that aren't objects, or lack a required id (`required:`), are dropped: they
#   can't be matched to an input item.
#
# Anything else raises Ai::Error::InvalidOutput, which escalates.
module Ai::Schema
  module_function

  def coerce(json, schema, aliases: {}, match: {}, required: [])
    options = { aliases: stringify(aliases), match: match.transform_keys(&:to_s), required: required.map(&:to_s) }
    json = wrap(json, schema, options[:aliases])
    raise Ai::Error::InvalidOutput, "expected a JSON object, got #{json.class.name.downcase}" unless json.is_a?(Hash)

    object(json, schema, options).tap do |value|
      list = array_property(schema)
      raise Ai::Error::InvalidOutput, "no #{list} in the answer" if list && !value[list.to_sym].is_a?(Array)
    end
  end

  # The one array property a batched schema wraps its items in (categorizations, merchants).
  def array_property(schema)
    keys = schema[:properties].to_h.select { |_, spec| Array(spec[:type]).map(&:to_s).include?("array") }.keys
    keys.one? ? keys.first.to_s : nil
  end

  def wrap(json, schema, aliases)
    list = array_property(schema)
    return json unless list
    return { list => json } if json.is_a?(Array)
    return json unless json.is_a?(Hash)

    key = ([ list ] + Array(aliases[list])).find { json.key?(_1) }
    key && key != list ? json.merge(list => json[key]) : json
  end

  def object(json, spec, options)
    json = json.stringify_keys
    spec[:properties].to_h.to_h do |key, property|
      key = key.to_s
      raw = ([ key ] + Array(options[:aliases][key])).map { json[_1] }.find { !_1.nil? }
      [ key.to_sym, value(raw, property, key, options) ]
    end
  end

  def value(raw, spec, key, options)
    raw = nil if raw.is_a?(String) && (raw.strip.empty? || raw.strip.casecmp?("null"))
    return nil if raw.nil?

    types = Array(spec[:type]).map(&:to_s)
    if types.include?("array")
      return nil unless raw.is_a?(Array)

      items = raw.select { _1.is_a?(Hash) }.map { object(_1, spec[:items], options) }
      return items.reject { |item| options[:required].any? { item[_1.to_sym].nil? } }
    end
    return (raw.is_a?(Hash) ? object(raw, spec, options) : nil) if types.include?("object")

    typed = typed(raw, types)
    return nil if typed.nil?
    return options[:match][key].call(typed) if options[:match].key?(key)
    return nil if spec[:enum] && !spec[:enum].include?(typed)
    return nil if spec[:minimum] && typed < spec[:minimum]
    return nil if spec[:maximum] && typed > spec[:maximum]

    typed
  end

  def typed(raw, types)
    return integer(raw) if types.include?("integer")
    return number(raw) if types.include?("number")
    return [ true, false ].include?(raw) ? raw : nil if types.include?("boolean")
    return raw.to_s.strip.presence if types.include?("string") && (raw.is_a?(String) || raw.is_a?(Numeric))
    return nil if types.include?("string")

    raw
  end

  def number(raw)
    return raw if raw.is_a?(Numeric)

    Float(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def integer(raw)
    number = number(raw)
    number && number == number.floor ? number.to_i : nil
  end

  def stringify(aliases) = aliases.to_h { |key, names| [ key.to_s, Array(names).map(&:to_s) ] }
end
