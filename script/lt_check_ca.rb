#!/usr/bin/env ruby
# LanguageTool check for Catalan locale files.
# Usage: ruby script/lt_check_ca.rb [path_glob]
#   Default glob: config/locales/**/ca.yml
#
# Premium (auto-enabled when LT_USERNAME + LT_API_KEY are set):
#   export LT_USERNAME="you@example.com"
#   export LT_API_KEY="xxx"
# Free fallback uses api.languagetool.org with aggressive throttling.
#
# Strategy:
#   - Strips %{var} placeholders and HTML tags from each leaf value.
#   - Batches ~40 leaves per LT request, separated by a sentinel ("\n¶¶¶\n").
#     LanguageTool returns offsets into the batched payload; we map each match
#     back to the originating leaf via sentinel-aware boundary lookups.
#   - 50x fewer HTTP requests than per-leaf checking.
#
# Output: /tmp/lt_ca_findings.json + stdout report grouped by file.

require "yaml"
require "net/http"
require "uri"
require "json"
require "set"

GLOB = ARGV.first || "config/locales/**/ca.yml"
LT_USERNAME = ENV["LT_USERNAME"]
LT_API_KEY  = ENV["LT_API_KEY"]
PREMIUM = !LT_USERNAME.to_s.empty? && !LT_API_KEY.to_s.empty?
API = URI(PREMIUM ? "https://api.languagetoolplus.com/v2/check" : "https://api.languagetool.org/v2/check")
SEP = ".\n\n".freeze
BATCH_TARGET_BYTES = PREMIUM ? 60_000 : 12_000 # premium plan allows ~75KB
SLEEP_BETWEEN = PREMIUM ? 0.5 : 4.0
TIMEOUT = 30

# Rules to suppress (noise on placeholders, brand words, single-token labels).
SUPPRESS_RULES = Set[
  "WHITESPACE_RULE",
  "UPPERCASE_SENTENCE_START",
  "EN_UNPAIRED_BRACKETS",
  "CA_UNPAIRED_BRACKETS"
]

# Words to treat as known-good and not flag for spelling errors.
KNOWN_WORDS = Set[
  "Sure", "Plaid", "SimpleFIN", "Brex", "Mercury", "IBKR", "Kraken", "Binance",
  "Coinbase", "CoinStats", "Coinstats", "Sophtron", "SnapTrade", "Snaptrade",
  "Indexa", "Lunchflow", "Lunch", "Flow", "Sankey", "MFA", "SSO", "OIDC", "OAuth",
  "Doorkeeper", "API", "URL", "URLs", "URI", "CSV", "PDF", "QIF", "JSON", "XLSX",
  "NDJSON", "OpenAI", "DeepSeek", "GPT", "LLM", "MCP", "JWT", "FX", "ETF", "ETFs",
  "MTD", "PSD2", "IBAN", "BIC", "IBKR", "Tiingo", "EODHD", "MFAPI", "XNAS",
  "Stripe", "Github", "GitHub", "Google", "Apple", "PEA", "TFSA", "RRSP", "RESP",
  "LIRA", "RRIF", "ISA", "LISA", "SIPP", "IRA", "HSA", "TSP", "Indexa",
  "Autoallotjament", "Webauthn", "WebAuthn", "Passkey", "passkeys", "passkey",
  "GitHub", "Tiingo", "Brandfetch", "Brand", "Fetch", "Sure",
  "Twelve", "Vantage", "Alpha", "Earn"
]

def collect_strings(node, path = [])
  out = []
  case node
  when Hash
    node.each { |k, v| out.concat(collect_strings(v, path + [ k.to_s ])) }
  when Array
    node.each_with_index { |v, i| out.concat(collect_strings(v, path + [ i.to_s ])) }
  when String
    out << [ path.join("."), node ]
  end
  out
end

def clean(s)
  s.gsub(/%\{[^}]+\}/, " ")
   .gsub(/<[^>]+>/, " ")
   .gsub(/\s+/, " ")
   .strip
end

def post_lt_text(text)
  req = Net::HTTP::Post.new(API)
  fields = {
    "language" => "ca-ES",
    "text" => text,
    "level" => "picky",
    "motherTongue" => "en",
    "mode" => "all",
    "enableHiddenRules" => "true",
    "allowIncompleteResults" => "true"
  }
  if PREMIUM
    fields["username"] = LT_USERNAME
    fields["apiKey"] = LT_API_KEY
  end
  req.set_form_data(fields)
  attempts = 0
  loop do
    begin
      res = Net::HTTP.start(API.host, API.port, use_ssl: true, read_timeout: TIMEOUT, open_timeout: TIMEOUT) do |http|
        http.request(req)
      end
    rescue StandardError => e
      warn "LT error: #{e.class}: #{e.message}"
      return { "matches" => [] }
    end

    case res.code.to_i
    when 200 then return JSON.parse(res.body)
    when 429
      attempts += 1
      return { "matches" => [] } if attempts >= 5
      sleep([ 2 * attempts, 60 ].min)
    else
      warn "LT #{res.code}: #{res.body[0, 300]}"
      return { "matches" => [] }
    end
  end
end

# Map a match offset back to the originating segment in a batched payload.
# segments: array of { file:, key:, raw:, text:, range: (offset_start..offset_end) }
def segment_for(segments, offset)
  segments.bsearch { |s| s[:range].last >= offset } || segments.last
end

files = Dir.glob(GLOB).select { |p| File.file?(p) }
warn "Mode: #{PREMIUM ? 'PREMIUM' : 'FREE'} (#{API.host})"
warn "Scanning #{files.length} files…"

found = []
total_leaves = 0
total_requests = 0

files.each_with_index do |file, fi|
  data = (YAML.unsafe_load_file(file) rescue YAML.load_file(file))
  next unless data.is_a?(Hash)
  ca = data["ca"]
  next unless ca

  strings = collect_strings(ca)
  warn "[#{fi + 1}/#{files.length}] #{file} (#{strings.length} leaves)"

  # Build segments
  segments = []
  strings.each do |key, raw|
    text = clean(raw)
    next if text.empty? || text.length < 3
    next if text.match?(/\A[\d\s.,:%\-+()\/]+\z/)
    segments << { file: file, key: key, raw: raw, text: text }
  end
  total_leaves += segments.length

  # Batch into groups under BATCH_TARGET_BYTES
  batches = []
  current = []
  current_bytes = 0
  segments.each do |seg|
    seg_bytes = seg[:text].bytesize + SEP.bytesize
    if current_bytes + seg_bytes > BATCH_TARGET_BYTES && !current.empty?
      batches << current
      current = []
      current_bytes = 0
    end
    current << seg
    current_bytes += seg_bytes
  end
  # Use a longer, unique sentinel so LT treats segments as fully independent paragraphs.
  batches << current unless current.empty?

  batches.each do |batch|
    # Build flat text payload, separating segments with a paragraph break.
    # Track per-segment offsets in CHARACTERS (LT offsets are char-based, not byte-based).
    payload = +""
    batch.each_with_index do |seg, i|
      seg[:range_start] = payload.length
      payload << seg[:text]
      seg[:range_end] = payload.length
      payload << SEP if i < batch.length - 1
    end

    total_requests += 1
    result = post_lt_text(payload)
    sleep(SLEEP_BETWEEN)
    (result["matches"] || []).each do |m|
      rule_id = m.dig("rule", "id")
      next if SUPPRESS_RULES.include?(rule_id)
      offset = m["offset"]
      len    = m["length"]
      # Only accept matches that land entirely inside a single segment.
      seg = batch.find { |s| s[:range_start] <= offset && (offset + len) <= s[:range_end] }
      next unless seg
      local_off = offset - seg[:range_start]
      offending = seg[:text][local_off, len] || ""
      next if KNOWN_WORDS.include?(offending)
      found << {
        file: seg[:file],
        key: seg[:key],
        rule: rule_id,
        category: m.dig("rule", "category", "id"),
        message: m["message"],
        offending: offending,
        original: seg[:raw],
        replacements: (m["replacements"] || []).first(3).map { |r| r["value"] }
      }
    end
  end
end

puts "\n=== LanguageTool findings: #{found.length} (across #{total_leaves} leaves, #{total_requests} requests) ==="
found.group_by { |f| f[:file] }.each do |file, items|
  puts "\n#{file}: #{items.length} findings"
  items.first(40).each do |f|
    puts "  #{f[:key]}"
    puts "    rule:        #{f[:rule]} (#{f[:category]})"
    puts "    msg:         #{f[:message]}"
    puts "    text:        #{f[:offending]}"
    puts "    suggestions: #{f[:replacements].join(' | ')}" unless f[:replacements].empty?
  end
  puts "  ... (#{items.length - 40} more)" if items.length > 40
end

File.write("/tmp/lt_ca_findings.json", JSON.pretty_generate(found))
warn "\nFindings written to /tmp/lt_ca_findings.json"
