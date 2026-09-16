require "json"

# Exactly one public ISS history response. Request routing and normalization are
# derived from pinned application policy, never from a returned continuation URL.
class Provider::AccountData::OnchainWallet::MoexFxReader
  MAX_BYTES = 1024 * 1024
  PAGE_SIZE = 100
  MAX_PAGES = 500
  POLICY = "moex-cets-dated-history/v1".freeze
  INSTRUMENTS = { "USD" => "USD000UTSTOM", "EUR" => "EUR_RUB__TOM", "CNY" => "CNYRUB_TOM" }.freeze
  COLUMNS = %w[boardid secid tradedate close waprice].freeze
  EnvelopeError = Provider::AccountData::OnchainWallet::Readers::InvalidResponse

  class Http
    include HTTParty
    extend SslConfigurable
    default_options.merge!({ timeout: 20, max_retries: 0 }.merge(httparty_ssl_options))
  end

  def self.policy
    { "format" => POLICY, "lookback_days" => 10, "page_size" => PAGE_SIZE,
      "max_pages" => MAX_PAGES, "current_quotes" => "unavailable_without_date_proof" }
  end

  def self.validate_options!(options)
    policy = options.fetch("history_policy")
    raise ArgumentError unless options["version"] == 1 && options["provider"] == "moex_public" && policy.is_a?(Hash) &&
      policy.keys.sort == self.policy.keys.sort && policy.except("max_pages") == self.policy.except("max_pages") &&
      policy["max_pages"].is_a?(Integer) && policy["max_pages"].between?(1, MAX_PAGES)
    policy
  end

  def self.request(options:, from:, to:, date:, start:)
    policy = validate_options!(options)
    Provider::AccountData::OnchainWallet::FxReader.request(from: from, to: to, date: date)
    raise ArgumentError unless start.is_a?(Integer) && start >= 0 && (start % PAGE_SIZE).zero? && start < policy.fetch("max_pages") * PAGE_SIZE
    currency = to == "RUB" ? from : (from == "RUB" ? to : nil)
    instrument = INSTRUMENTS[currency]
    raise ArgumentError if instrument.nil? && start != 0
    { "from" => from, "to" => to, "date" => date.iso8601, "start" => start,
      "history_from" => (date - policy.fetch("lookback_days")).iso8601, "history_till" => date.iso8601,
      "board" => "CETS", "instrument" => instrument, "inverted" => from == "RUB", "policy" => POLICY }
  end

  def initialize(options:, http: Http)
    self.class.validate_options!(options)
    @options = options.deep_dup
    @endpoint = Provider::AccountData::OnchainWallet::Readers::Transport.endpoint(options.fetch("endpoint"))
    @interval = Float(options.fetch("min_interval_seconds"))
    raise ArgumentError unless @interval.finite? && @interval.between?(0.15, 60)
    @http = http
  end

  def read(from:, to:, date:, start:)
    request = self.class.request(options: @options, from: from, to: to, date: date, start: start)
    raise Provider::AccountData::InvalidResponse, "Wallet FX requests cannot run in a database transaction" if ApplicationRecord.connection.transaction_open?
    if request["instrument"].nil?
      return { "version" => 1, "provider" => "moex_public", "request" => request, "status" => "unsupported_pair", "history" => nil }
    end
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep([ @interval - (now - @last_request_at), 0 ].max) if @last_request_at
    @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = @http.get("#{@endpoint}/history/engines/currency/markets/selt/boards/CETS/securities/#{request.fetch('instrument')}.json",
      query: { "iss.meta" => "off", "iss.only" => "history", "from" => request.fetch("history_from"), "till" => request.fetch("history_till"), "start" => start },
      headers: { "Accept" => "application/json" }, follow_redirects: false)
    code = response.code.to_i
    raise Provider::AccountData::OnchainWallet::Readers::RateLimited, "Wallet MOEX endpoint rate limit exceeded" if code == 429
    raise Provider::AccountData::OnchainWallet::Readers::AuthenticationError, "Wallet MOEX endpoint authentication failed" if [ 401, 403 ].include?(code)
    raise EnvelopeError, "Wallet MOEX endpoint request failed" unless code.between?(200, 299)
    body = response.body
    raise ArgumentError unless body.is_a?(String) && body.bytesize <= MAX_BYTES
    parsed = JSON.parse(body, decimal_class: BigDecimal)
    raise ArgumentError unless parsed.is_a?(Hash)
    capture = { "version" => 1, "provider" => "moex_public", "request" => request, "status" => "response", "history" => self.class.selected_history(parsed.fetch("history")) }
    self.class.rows(capture, options: @options, from: from, to: to, date: date, start: start)
    capture
  rescue ArgumentError, TypeError, KeyError, JSON::ParserError
    raise EnvelopeError, "Invalid wallet MOEX history response", cause: nil
  rescue *Provider::HttpTransport::TRANSPORT_ERRORS
    raise Provider::AccountData::OnchainWallet::Readers::Error, "Wallet MOEX endpoint is unavailable", cause: nil
  end

  def self.rows(capture, options:, from:, to:, date:, start:)
    expected = request(options: options, from: from, to: to, date: date, start: start)
    raise ArgumentError unless capture.is_a?(Hash) && capture.keys.sort == %w[history provider request status version] &&
      capture["version"] == 1 && capture["provider"] == "moex_public" && capture["request"] == expected
    if expected["instrument"].nil?
      raise ArgumentError unless capture["status"] == "unsupported_pair" && capture["history"].nil?
      return nil
    end
    raise ArgumentError unless capture["status"] == "response"
    history = selected_history(capture.fetch("history"))
    # Selected captures cannot smuggle extra values past their original scrubber.
    raise ArgumentError unless history == capture["history"]
    columns = history.fetch("columns").map(&:downcase)
    history.fetch("data").map do |values|
      row = columns.zip(values).to_h
      raise ArgumentError unless row["boardid"] == expected["board"] && row["secid"] == expected["instrument"]
      day = exact_date(row["tradedate"])
      raise ArgumentError unless day && day.between?(date - 10, date)
      field = row["close"].present? ? "close" : "waprice"
      raw = row[field]
      rate = Provider::AccountData::OnchainWallet::SnapshotArchive.decimal(raw) if raw.present?
      { "date" => day.iso8601, "rate" => rate&.positive? ? rate.to_s("F") : nil, "field" => field }
    end
  rescue ArgumentError, TypeError, KeyError
    raise EnvelopeError, "Invalid captured wallet MOEX history", cause: nil
  end

  def self.selected_history(section)
    raise ArgumentError unless section.is_a?(Hash)
    columns, data = section.values_at("columns", "data")
    raise ArgumentError unless columns.is_a?(Array) && columns.size <= 256 && columns.all? { |column| column.is_a?(String) && column.match?(/\A[A-Za-z][A-Za-z0-9_]{0,63}\z/) }
    names = columns.map(&:downcase)
    raise ArgumentError unless names.uniq == names && (%w[boardid secid tradedate] - names).empty? && (names & %w[close waprice]).any?
    raise ArgumentError unless data.is_a?(Array) && data.size <= PAGE_SIZE && data.all? { |row| row.is_a?(Array) && row.size == columns.size }
    indices = names.each_index.select { |index| COLUMNS.include?(names[index]) }
    selected = data.map do |row|
      indices.map do |index|
        value = row.fetch(index)
        raise ArgumentError unless value.nil? || value.is_a?(Integer) || value.is_a?(BigDecimal) || (value.is_a?(String) && value.bytesize <= 128)
        value
      end
    end
    { "columns" => indices.map { |index| columns.fetch(index) }, "data" => selected }
  end

  def self.exact_date(value)
    return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    day = Date.iso8601(value)
    day if day.iso8601 == value
  end
  private_class_method :exact_date

  def inspect
    "#<#{self.class.name}>"
  end
end
