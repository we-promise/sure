require "yaml"

# Explicit files only: English fallback must never satisfy coverage.
module ApplicationLocaleCatalog
  FRAMEWORK_ROOTS = %w[activerecord date datetime errors helpers number support time].freeze
  PLURAL_KEYS = %w[zero one two few many other].freeze

  def self.catalog
    @catalog ||= begin
      locales = LanguagesHelper::SUPPORTED_LOCALES
      app = locales.index_with { {} }
      english_reference = {}
      Rails.root.glob("config/locales/**/*.yml").sort.each do |path|
        document = YAML.safe_load(path.read, permitted_classes: [ Date, Time, Symbol ], aliases: true, filename: path.to_s)
        document.each do |locale, translations|
          locale = locale.to_s
          next unless app.key?(locale) && translations.is_a?(Hash)

          tree = translations.deep_stringify_keys
          if locale == "en"
            reference_tree = path.relative_path_from(Rails.root).to_s.start_with?("config/locales/defaults/") ? tree.except(*FRAMEWORK_ROOTS) : tree
            english_reference = english_reference.deep_merge(reference_tree)
          end
          app[locale] = app[locale].deep_merge(tree)
        end
      end
      @reference = english_reference
      app
    end
  end

  def self.reference
    catalog
    @reference
  end

  def self.plural?(value)
    value.is_a?(Hash) && value.key?("other") && (value.keys - PLURAL_KEYS).empty?
  end

  def self.messages(value, prefix = nil)
    return { prefix => value } unless value.is_a?(Hash)
    return { prefix => value } if plural?(value)

    value.each_with_object({}) do |(key, child), out|
      out.merge!(messages(child, [ prefix, key ].compact.join(".")))
    end
  end

  def self.tokens(value)
    case value
    when String
      value.scan(/(?<!%)%\{([^}]+)\}|(?<!%)%<([^>]+)>/).flatten.compact.uniq.sort
    when Hash
      value.values.flat_map { |child| tokens(child) }.uniq.sort
    when Array
      value.flat_map { |child| tokens(child) }.uniq.sort
    else
      []
    end
  end

  # The subscription view explicitly supplies both names from the same value.
  # Keep legitimate locale pluralizations that interpolate count instead of days.
  def self.javascript_tokens(value)
    case value
    when String
      value.scan(/(?<![%$\{])\{([A-Za-z][A-Za-z0-9_]*)\}(?!\})/).flatten.map { |name| "JS:#{name}" }
    when Hash
      value.values.flat_map { |child| javascript_tokens(child) }
    when Array
      value.flat_map { |child| javascript_tokens(child) }
    else
      []
    end
  end

  def self.message_tokens(key, value)
    names = tokens(value)
    names = names.map { |name| name == "count" ? "days" : name } if key == "subscriptions.upgrade.trialing"
    (names + javascript_tokens(value)).uniq.sort
  end

  def self.blank?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
  end

  def self.html_signature(value)
    return [] unless value.is_a?(String)

    Nokogiri::HTML.fragment(value).css("*").map do |node|
      attributes = node.attribute_nodes.map do |attr|
        value = attr.value
        if attr.name == "class"
          aliases = { "text-red-500" => "text-destructive", "text-red-600" => "text-destructive", "text-green-600" => "text-success" }
          value = value.split.map { |token| aliases.fetch(token, token) }.sort.join(" ")
        end
        [ attr.name, value ]
      end
      [ node.name, attributes.sort ]
    end
  end
end
