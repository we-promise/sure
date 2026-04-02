#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "yaml"

PLURAL_KEYS = %w[zero one two few many other].freeze

LOCALE_PLURAL_REQUIREMENTS = {
  "pl" => %w[one few many other]
}.freeze

COMMON_ENGLISH_UI = [
  /\b(add|edit|delete|remove|save|cancel|confirm|create|update|export|upload|download|link|unlink|sync|loading|overview|settings|details|summary|dashboard|account|accounts|transaction|transactions|trade|trades|holding|holdings|report|reports|budget|budgets|category|categories|filter|filters|search|view|open|close|continue|back|next|previous|title|description|warning|error|success|failed|pending|confirmed|income|expense|expenses|assets|debts|cash|loan|loans|credit card|provider|providers|document|documents|privacy policy|terms of service|net worth|cashflow|outflows)\b/i,
  /\b(please|choose|select|showing|ready|drop|browse|processing|start import|new account|no accounts|missing data|configure|copy url|open google sheets)\b/i
].freeze

ENGLISH_SIGNAL_WORDS = %w[
  add edit delete remove save cancel confirm create update export upload download
  link unlink sync loading overview settings details summary dashboard account
  accounts transaction transactions trade trades holding holdings report reports
  budget budgets category categories filter filters search view open close continue
  back next previous title description warning error success failed pending confirmed
  income expense expenses assets debts cash loan loans credit provider providers
  document documents privacy policy terms service net worth cashflow outflows
  please choose select showing ready drop browse processing missing configure copy
].freeze

LOCALE_LANGUAGE_SIGNALS = {
  "pl" => %w[
    ąć ę ł ń ó ś ź ż
    nie jest został została zostały włącz wyłącz
    konto konta kont transakcj ustawień ustawienia
    wybierz dodaj usuń usun edytuj zaktualizuj synchronizuj
    plik dane brak pomyślnie wymaga konfiguracji przejdź
    połącz zaimportuj kategoria tagów
  ]
}.freeze

ENGLISH_WHITELIST = [
  /Doorkeeper/, /OAuth/, /OIDC/, /SAML/, /Lucide/, /Google Sheets/, /Google/, /CSV/, /PDF/, /QIF/, /NDJSON/,
  /IndexaCapital/, /Lunch Flow/, /Lunchflow/, /Mercury/, /CoinStats/, /Coinbase/, /SimpleFIN/, /Plaid/, /Maybe/, /Sure/,
  /Keycloak/, /Authentik/, /URI/, /URL/, /API/, /IBAN/, /SWIFT/, /X\.509/, /PEM/, /PKCE/,
  /AAPL/, /MSFT/, /XNAS/, /LLM/, /AI/
].freeze

def parse_args!
  options = {
    locale: nil,
    write_reports: false,
    plural_categories: nil
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby script/locale_audit.rb --locale LOCALE [--write-reports]"

    opts.on("--locale LOCALE", "Locale code, e.g. pl, fr, de, pt-BR") do |value|
      options[:locale] = value
    end

    opts.on("--write-reports", "Write markdown reports into docs/localization/") do
      options[:write_reports] = true
    end

    opts.on("--plural-categories LIST", "Comma-separated required plural keys (e.g. one,other or one,few,many,other)") do |value|
      options[:plural_categories] = value
    end
  end

  parser.parse!

  if options[:locale].nil? || options[:locale].strip.empty?
    warn "Missing required argument: --locale"
    warn parser.banner
    exit 1
  end

  options
end

def base_locale(locale)
  locale.to_s.split(/[-_]/).first
end

def expected_plural_categories(locale, override)
  return override.split(",").map(&:strip).reject(&:empty?).uniq if override

  LOCALE_PLURAL_REQUIREMENTS.fetch(base_locale(locale), %w[one other])
end

def locale_file?(path, locale)
  base = File.basename(path)
  base == "#{locale}.yml" || base.end_with?(".#{locale}.yml")
end

def load_yaml_file(file)
  YAML.safe_load(
    File.read(file),
    permitted_classes: [ Symbol, Date, Time ],
    permitted_symbols: [],
    aliases: true
  )
end

def walk(obj, path = [], &block)
  case obj
  when Hash
    yield(obj, path)
    obj.each { |k, v| walk(v, path + [ k.to_s ], &block) }
  when Array
    obj.each_with_index { |v, i| walk(v, path + [ i.to_s ], &block) }
  end
end

def suspicious_english?(value, language_signals)
  return false unless value.is_a?(String)

  stripped = value.strip
  return false if stripped.empty?
  return false if stripped.match?(%r{https?://})
  return false if stripped.match?(/\A[%\-+()\[\]{}<>=:;,.0-9\s]+\z/)

  normalized = stripped.gsub(/%\{[^}]+\}/, "")
  lowered = normalized.downcase

  return false if ENGLISH_WHITELIST.any? { |pattern| normalized.match?(pattern) }

  # Guard against false positives on correctly translated strings containing
  # shared words like "status", "tag", "import" or technical terms.
  locale_signals = language_signals.count { |snippet| lowered.include?(snippet) }
  english_tokens = lowered.scan(/[a-z]+/)
  english_signal_hits = english_tokens.count { |token| ENGLISH_SIGNAL_WORDS.include?(token) }

  return false if locale_signals >= 1 && english_signal_hits < 3

  COMMON_ENGLISH_UI.any? { |pattern| normalized.match?(pattern) } || english_signal_hits >= 3
end

def real_plural_block?(node)
  return false unless node.is_a?(Hash)

  keys = node.keys.map(&:to_s)
  return false if (keys & PLURAL_KEYS).empty?
  return false unless keys.all? { |k| PLURAL_KEYS.include?(k) }

  node.values.all? { |v| v.is_a?(String) || v.is_a?(Numeric) }
end

def audit_file(file, required_plural_categories, language_signals)
  data = load_yaml_file(file)
  english_hits = []
  plural_missing = []

  walk(data) do |node, path|
    if node.is_a?(Hash)
      node.each do |k, v|
        next unless v.is_a?(String)
        next unless suspicious_english?(v, language_signals)

        english_hits << [ path + [ k.to_s ], v ]
      end

      next unless real_plural_block?(node)

      keys = node.keys.map(&:to_s)
      next unless keys.include?("one") && keys.include?("other")

      missing = required_plural_categories - keys
      if missing.any?
        plural_missing << [ path, keys.sort, missing ]
      end
    end
  end

  {
    file: file,
    english_hits: english_hits,
    plural_missing: plural_missing
  }
end

def readiness_status(result)
  result[:english_hits].empty? && result[:plural_missing].empty? ? "OK" : "NEEDS_WORK"
end

def build_readiness_report(locale, results, required_plural_categories)
  ok = results.select { |r| readiness_status(r) == "OK" }
  needs = results.select { |r| readiness_status(r) == "NEEDS_WORK" }

  lines = []
  lines << "# Locale production readiness (#{locale})"
  lines << ""
  lines << "Audit scope: #{results.size} files"
  lines << ""
  lines << "Summary:"
  lines << "- OK: #{ok.size}"
  lines << "- NEEDS_WORK: #{needs.size}"
  lines << ""
  lines << "Criteria:"
  lines << "- OK: no suspicious untranslated English strings and no plural blocks missing required categories"
  lines << "- NEEDS_WORK: contains suspicious untranslated English strings or plural blocks missing required categories"
  lines << "- Required plural categories for #{locale}: #{required_plural_categories.join(', ')}"
  lines << ""
  lines << "## OK"
  ok.each { |r| lines << "- #{r[:file]}" }
  lines << ""
  lines << "## NEEDS_WORK"

  if needs.empty?
    lines << "- None"
  else
    needs.each do |r|
      lines << "- #{r[:file]}"
      if r[:english_hits].any?
        lines << "  reason: suspicious untranslated English strings (#{r[:english_hits].size})"
        sample = r[:english_hits].first(3).map { |path, value| "#{path.join('.')}=#{value}" }
        lines << "  examples: #{sample.join(' | ')}"
      end
      if r[:plural_missing].any?
        lines << "  reason: plural blocks missing required categories (#{r[:plural_missing].size})"
        sample = r[:plural_missing].first(3).map { |path, keys, missing| "#{path.join('.')} keys=#{keys.join(',')} missing=#{missing.join(',')}" }
        lines << "  examples: #{sample.join(' | ')}"
      end
    end
  end

  lines.join("\n") + "\n"
end

def build_plural_report(locale, results, required_plural_categories)
  missing = []
  results.each do |r|
    r[:plural_missing].each do |path, keys, missing_keys|
      missing << [ r[:file], path.join('.'), keys.join(','), missing_keys.join(',') ]
    end
  end

  lines = []
  lines << "# Locale pluralization audit (#{locale})"
  lines << ""
  lines << "Scope: #{results.size} files"
  lines << ""
  lines << "Required plural categories for #{locale}: #{required_plural_categories.join(', ')}"
  lines << "Result: #{missing.size} pluralization blocks are missing one or more required categories."
  lines << ""
  lines << "## Findings"
  if missing.empty?
    lines << "- None. All detected pluralization blocks include required categories."
  else
    missing.each do |file, path, keys, missing_keys|
      lines << "- #{file} | #{path} | keys=#{keys} | missing=#{missing_keys}"
    end
  end

  lines.join("\n") + "\n"
end

options = parse_args!
locale = options[:locale]
required_plural_categories = expected_plural_categories(locale, options[:plural_categories])
language_signals = LOCALE_LANGUAGE_SIGNALS.fetch(base_locale(locale), [])

files = Dir["config/locales/**/*.yml"].sort.select { |path| locale_file?(path, locale) }
results = files.map { |file| audit_file(file, required_plural_categories, language_signals) }

puts "LOCALE=#{locale}"
puts "REQUIRED_PLURAL_CATEGORIES=#{required_plural_categories.join(',')}"
puts "FILES=#{files.size}"
puts "FILES_WITH_ENGLISH_HITS=#{results.count { |r| r[:english_hits].any? }}"
puts "PLURAL_BLOCKS_MISSING_REQUIRED_CATEGORIES=#{results.sum { |r| r[:plural_missing].size }}"

if options[:write_reports]
  Dir.mkdir("docs/localization") unless Dir.exist?("docs/localization")

  readiness_path = "docs/localization/#{locale}_production_readiness.md"
  plural_path = "docs/localization/#{locale}_pluralization_audit.md"

  File.write(readiness_path, build_readiness_report(locale, results, required_plural_categories))
  File.write(plural_path, build_plural_report(locale, results, required_plural_categories))

  puts "WROTE #{readiness_path}"
  puts "WROTE #{plural_path}"
end
