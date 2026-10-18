# frozen_string_literal: true

require "bigdecimal"
require "json"
require "net/http"
require "openssl"
require "socket"
require "timeout"
require "uri"

class Provider::Directa
  HOST = "www1.directatrading.com".freeze
  HTTPS_PORT = 443
  TRADING_PORT = 2080
  USER_AGENT = "/dcl".freeze

  LOGIN_PATH = "/trading/collegc_3".freeze
  ACCOUNT_IDENTITY_PATH = "/trading/gesdec".freeze
  STARTUP_METADATA_PATH = "/trading/tbjson02".freeze
  INSTRUMENT_METADATA_PATH = "/anagra/listtit1r".freeze

  MAX_ACCOUNT_NUMBER_BYTES = 32
  MAX_PASSWORD_BYTES = 512
  MAX_OTP_BYTES = 12
  MAX_CHALLENGE_BYTES = 512
  MAX_TOKEN_BYTES = 128
  MAX_INSTRUMENT_CODES = 256
  MAX_INSTRUMENT_CODE_BYTES = 64
  MAX_SNAPSHOT_POSITIONS = 2_000
  REQUEST_TIMEOUT_SECONDS = 25
  HTTP_BODY_LIMIT_BYTES = 2 * 1024 * 1024
  DECIMAL_MAX_INPUT_BYTES = 64
  DECIMAL_MAX_SIGNIFICANT_DIGITS = 32
  DECIMAL_MAX_SCIENTIFIC_EXPONENT = 32
  DECIMAL_MIN_NONZERO_VALUE = BigDecimal("1e-32")
  DECIMAL_MAX_VALUE = BigDecimal("1e32")
  DECIMAL_PATTERN = /\A[+-]?(?<mantissa>\d+(?:[.,]\d+)?)(?:[eE](?<exponent>[+-]?\d+))?\z/
  CURRENCY_SOURCE = "Directa documented liquidity semantics; type 60 field 7".freeze
  FIELD_SOURCES = {
    cash_amount: "trading type 60 field 7",
    cash_equity_availability: "trading type 60 field 3",
    cash_margin_availability: "trading type 60 field 5",
    cash_realtime_availability: "trading type 60 field 9",
    cash_performance: "trading type 60 field 8",
    position_univoco: "trading type 70 field 5",
    position_quantity: "trading type 70 field 9",
    position_average_price: "trading type 70 field 10",
    instrument_requested_code: "listtit titoli[].CodiceRichiesto",
    instrument_canonical_code: "listtit titoli[].Codice",
    instrument_isin: "listtit titoli[].Isin",
    instrument_currency: "listtit titoli[].Divisa",
    instrument_description: "listtit titoli[].Descriz",
    instrument_market: "listtit titoli[].MercNeg",
    instrument_segment: "listtit titoli[].Segmento",
    instrument_phase: "listtit titoli[].TFase",
    instrument_type: "listtit titoli[].TTipo",
    instrument_authorization_markets: "listtit titoli[].MercAbilitazioni",
    instrument_multiplier: "listtit titoli[].Moltip",
    instrument_reference_price: "listtit titoli[].PrzRif",
    instrument_price_codes: "listtit titoli[].CodPrezzi",
    instrument_tick_table: "listtit titoli[].TabTick",
    instrument_tick_size: "listtit titoli[].TickFisso"
  }.freeze

  class Error < Provider::Error
    def inspect
      "#<#{self.class.name}: #{failure_code}>"
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  class AccountIdentityMismatch < Error; end
  class InvalidResponse < Error; end
  class RequestTimeout < Error; end
  class ProviderUnavailable < Error; end
  class RedirectRejected < Error; end
  class ResponseTooLarge < Error; end
  class SequenceError < Error; end
  class StreamProtocolError < Error; end
  class SnapshotIncomplete < Error; end

  class LoginChallenge
    attr_reader :account_number, :challenge_token, :connection_generation

    def initialize(account_number:, challenge_token:, connection_generation:)
      @account_number = account_number.to_s.dup.freeze
      @challenge_token = challenge_token.to_s.dup.freeze
      @connection_generation = Integer(connection_generation)
      freeze
    end

    def inspect
      "#<#{self.class.name}: otp_required>"
    end
    alias to_s inspect

    def as_json(*)
      { state: "otp_required", account_number: account_number, connection_generation: connection_generation }
    end
  end

  class VerifiedSession
    attr_reader :account_number, :account_identity, :multi_token, :mono_token, :host, :connection_generation

    def initialize(account_number:, account_identity:, multi_token:, mono_token:, host:, connection_generation:)
      @account_number = account_number.to_s.dup.freeze
      @account_identity = account_identity.to_s.dup.freeze
      @multi_token = multi_token.to_s.dup.freeze
      @mono_token = mono_token.to_s.dup.freeze
      @host = host.to_s.dup.freeze
      @connection_generation = Integer(connection_generation)
      freeze
    end

    def inspect
      "#<#{self.class.name}: verified>"
    end
    alias to_s inspect

    def as_json(*)
      {
        account_number: account_number,
        account_identity: account_identity,
        host: host,
        connection_generation: connection_generation
      }
    end
  end

  class Cash
    attr_reader :amount, :raw_amount, :currency, :currency_status, :currency_source,
      :equity_availability, :equity_margin_availability, :realtime_availability,
      :consolidated_performance, :raw_fields, :field_sources

    def initialize(amount:, raw_amount:, equity_availability:, equity_margin_availability:,
      realtime_availability:, consolidated_performance:, raw_fields:, field_sources:)
      @amount = amount
      @raw_amount = raw_amount&.to_s&.dup&.freeze
      @currency = "EUR".freeze
      @currency_status = :verified
      @currency_source = CURRENCY_SOURCE
      @equity_availability = equity_availability&.to_s&.dup&.freeze
      @equity_margin_availability = equity_margin_availability&.to_s&.dup&.freeze
      @realtime_availability = realtime_availability&.to_s&.dup&.freeze
      @consolidated_performance = consolidated_performance&.to_s&.dup&.freeze
      @raw_fields = raw_fields.map { |field| field&.to_s&.dup&.freeze }.freeze
      @field_sources = field_sources.freeze
      freeze
    end

    def inspect
      "#<#{self.class.name}: snapshot>"
    end
    alias to_s inspect
  end

  class InstrumentMetadata
    attr_reader :requested_code, :canonical_code, :isin, :currency, :description,
      :directa_market, :directa_segment, :mic, :multiplier, :raw_multiplier,
      :price_codes, :tick_table, :tick_size, :raw_tick_size, :identity_status,
      :phase, :instrument_type, :authorization_markets, :reference_price, :field_sources

    def initialize(requested_code:, canonical_code:, isin:, currency:, description:,
      directa_market:, directa_segment:, multiplier:, raw_multiplier:, price_codes:,
      tick_table:, tick_size:, raw_tick_size:, identity_status:, field_sources:,
      phase: nil, instrument_type: nil, authorization_markets: [], reference_price: nil, mic: nil)
      @requested_code = requested_code&.to_s&.dup&.freeze
      @canonical_code = canonical_code&.to_s&.dup&.freeze
      @isin = isin&.to_s&.dup&.freeze
      @currency = currency&.to_s&.dup&.freeze
      @description = description&.to_s&.dup&.freeze
      @directa_market = directa_market&.to_s&.dup&.freeze
      @directa_segment = directa_segment&.to_s&.dup&.freeze
      @mic = mic&.to_s&.dup&.freeze
      @multiplier = multiplier
      @raw_multiplier = raw_multiplier&.to_s&.dup&.freeze
      @price_codes = Array(price_codes).map { |code| code.to_s.dup.freeze }.freeze
      @tick_table = tick_table&.to_s&.dup&.freeze
      @tick_size = tick_size
      @raw_tick_size = raw_tick_size&.to_s&.dup&.freeze
      @identity_status = identity_status
      @phase = phase&.to_s&.dup&.freeze
      @instrument_type = instrument_type&.to_s&.dup&.freeze
      @authorization_markets = Array(authorization_markets).map { |market| market.to_s.dup.freeze }.freeze
      @reference_price = reference_price
      @field_sources = field_sources.freeze
      freeze
    end

    def with_identity(mic:, identity_status:)
      self.class.new(
        requested_code: requested_code,
        canonical_code: canonical_code,
        isin: isin,
        currency: currency,
        description: description,
        directa_market: directa_market,
        directa_segment: directa_segment,
        multiplier: multiplier,
        raw_multiplier: raw_multiplier,
        price_codes: price_codes,
        tick_table: tick_table,
        tick_size: tick_size,
        raw_tick_size: raw_tick_size,
        identity_status: identity_status,
        field_sources: field_sources,
        phase: phase,
        instrument_type: instrument_type,
        authorization_markets: authorization_markets,
        reference_price: reference_price,
        mic: mic
      )
    end

    def inspect
      "#<#{self.class.name}: metadata>"
    end
    alias to_s inspect
  end

  class Position
    attr_reader :univoco, :quantity, :raw_quantity, :raw_average_price,
      :instrument_metadata, :identity_status, :valuation_status, :valuation_date,
      :valuation_currency, :current_price, :market_value, :unrealized_gain,
      :valuation_source, :valuation_details, :raw_fields, :field_sources

    def initialize(univoco:, quantity:, raw_quantity:, raw_average_price:, raw_fields:,
      instrument_metadata: nil, field_sources: FIELD_SOURCES, valuation_status: :unavailable,
      valuation_date: nil, valuation_currency: nil, current_price: nil, market_value: nil,
      unrealized_gain: nil, valuation_source: nil, valuation_details: nil)
      @univoco = univoco.to_s.dup.freeze
      @quantity = quantity
      @raw_quantity = raw_quantity&.to_s&.dup&.freeze
      @raw_average_price = raw_average_price&.to_s&.dup&.freeze
      @instrument_metadata = instrument_metadata
      @identity_status = instrument_metadata&.identity_status || :unresolved
      @valuation_status = valuation_status
      @valuation_date = valuation_date
      @valuation_currency = valuation_currency&.to_s&.dup&.freeze
      @current_price = current_price
      @market_value = market_value
      @unrealized_gain = unrealized_gain
      @valuation_source = valuation_source&.to_s&.dup&.freeze
      @valuation_details = valuation_details&.to_h&.transform_keys(&:to_s)&.transform_values { |value| value&.to_s&.dup&.freeze }&.freeze
      @raw_fields = raw_fields.map { |field| field&.to_s&.dup&.freeze }.freeze
      @field_sources = field_sources.freeze
      freeze
    end

    def inspect
      "#<#{self.class.name}: position>"
    end
    alias to_s inspect
  end

  class Snapshot
    attr_reader :account_number, :account_identity, :connection_generation, :observed_at,
      :cash_seen, :positions_complete, :full_photo_complete, :cash, :positions,
      :unknown_message_types, :field_sources

    def initialize(account_number:, account_identity:, connection_generation:, observed_at:,
      cash_seen:, positions_complete:, full_photo_complete:, cash:, positions:,
      unknown_message_types:, field_sources: FIELD_SOURCES)
      @account_number = account_number.to_s.dup.freeze
      @account_identity = account_identity.to_s.dup.freeze
      @connection_generation = Integer(connection_generation)
      @observed_at = observed_at.utc.freeze
      @cash_seen = !!cash_seen
      @positions_complete = !!positions_complete
      @full_photo_complete = !!full_photo_complete
      @cash = cash
      @positions = positions.freeze
      @unknown_message_types = unknown_message_types.uniq.freeze
      @field_sources = field_sources.freeze
      freeze
    end

    def complete?
      cash_seen && cash&.amount.is_a?(BigDecimal) && positions_complete && unknown_message_types.empty?
    end

    def inspect
      "#<#{self.class.name}: snapshot>"
    end
    alias to_s inspect
  end

  class InstrumentMetadataResult
    attr_reader :instruments, :missing_codes, :field_sources

    def initialize(instruments:, missing_codes:, field_sources: FIELD_SOURCES)
      @instruments = instruments.freeze
      @missing_codes = missing_codes.map { |code| code.to_s.dup.freeze }.freeze
      @field_sources = field_sources.freeze
      freeze
    end

    def complete?
      missing_codes.empty?
    end

    def inspect
      "#<#{self.class.name}: metadata>"
    end
    alias to_s inspect
  end

  def initialize(session: nil, http_transport: nil, trading_connection_factory: nil)
    @session = session
    @http_transport = http_transport || HttpTransport.new
    @trading_connection_factory = trading_connection_factory || ->(verified_session:) {
      TradingConnection.new(session: verified_session)
    }
  end

  def begin_login(account_number:, password:, connection_generation:)
    account = validate_account_number!(account_number)
    validate_generation!(connection_generation)
    secret = password.to_s.dup
    raise_error(ConfigurationError, :invalid_credentials, "Directa password is required.") if secret.empty? || secret.bytesize > MAX_PASSWORD_BYTES

    with_deadline do |deadline|
      response = @http_transport.request(
        :login,
        form: login_form(account, secret),
        deadline: deadline,
        body_limit: 64 * 1024
      )
      login_result(response, account_number: account, connection_generation: connection_generation, deadline: deadline)
    end
  ensure
    secret&.clear
  end

  def complete_login(account_number:, challenge_token:, otp_code:, connection_generation:)
    account = validate_account_number!(account_number)
    validate_generation!(connection_generation)
    challenge = challenge_token.to_s
    code = otp_code.to_s.dup
    raise_error(ConfigurationError, :challenge_not_available, "Directa OTP challenge is unavailable.") if challenge.empty? || challenge.bytesize > MAX_CHALLENGE_BYTES
    raise_error(ConfigurationError, :invalid_code, "Directa OTP code is invalid.") unless /\A[0-9]{1,#{MAX_OTP_BYTES}}\z/.match?(code)

    with_deadline do |deadline|
      response = @http_transport.request(
        :login,
        form: login_form(account, challenge, otp_code: code),
        deadline: deadline,
        body_limit: 64 * 1024
      )
      login_result(
        response,
        account_number: account,
        connection_generation: connection_generation,
        deadline: deadline,
        retry_challenge_token: challenge
      )
    end
  ensure
    code&.clear
  end

  def fetch_portfolio_snapshot
    verified_session = require_verified_session!
    with_deadline do |deadline|
      connection = @trading_connection_factory.call(verified_session: verified_session)
      result = connection.fetch_snapshot(deadline: deadline)
      unless result.is_a?(Snapshot) &&
          result.account_number == verified_session.account_number &&
          result.account_identity == verified_session.account_identity &&
          result.connection_generation == verified_session.connection_generation
        raise_error(StreamProtocolError, :session_mismatch, "Directa snapshot did not match the verified session.")
      end

      enrich_snapshot_metadata(result, verified_session, deadline: deadline)
    end
  rescue Error
    raise
  rescue StandardError
    raise_error(ProviderUnavailable, :provider_unavailable, "Directa portfolio service is unavailable.")
  end

  def fetch_instrument_metadata(codes:)
    verified_session = require_verified_session!
    requested_codes = validate_instrument_codes!(codes)
    return InstrumentMetadataResult.new(instruments: {}, missing_codes: []) if requested_codes.empty?

    with_deadline do |deadline|
      response = @http_transport.request(
        :instrument_metadata,
        query: instrument_metadata_query(verified_session.multi_token, requested_codes),
        deadline: deadline,
        body_limit: HTTP_BODY_LIMIT_BYTES
      )
      ensure_success_response!(response, :metadata_request_failed)
      payload = parse_json!(response.body, :metadata_response_invalid)
      parse_instrument_metadata(payload, requested_codes)
    end
  rescue Error
    raise
  rescue StandardError
    raise_error(ProviderUnavailable, :provider_unavailable, "Directa instrument metadata is unavailable.")
  end

  class << self
    def parse_cash_amount(value)
      raw = value.to_s.strip
      return if raw.empty?

      match = /\A(?<sign>[+-]?)(?<whole>\d{1,3}(?:\.\d{3})+|\d+)(?:,(?<fraction>\d+))?(?<trailing_minus>-)?\z/.match(raw)
      return unless match
      return if match[:sign].present? && match[:trailing_minus].present?

      normalized = "#{match[:sign]}#{match[:whole].delete(".")}#{match[:fraction] ? ".#{match[:fraction]}" : ""}"
      amount = BigDecimal(normalized)
      match[:trailing_minus] ? -amount.abs : amount
    rescue ArgumentError
      nil
    end

    def parse_decimal(value)
      raw = value.to_s.strip
      return if raw.empty? || raw.bytesize > DECIMAL_MAX_INPUT_BYTES

      match = DECIMAL_PATTERN.match(raw)
      return unless match

      exponent = match[:exponent]
      if exponent
        exponent_digits = exponent.delete("+-")
        return if exponent_digits.bytesize > 2 || exponent.to_i.abs > DECIMAL_MAX_SCIENTIFIC_EXPONENT
      end

      significant_digits = match[:mantissa].delete(".,").sub(/\A0+/, "").sub(/0+\z/, "")
      return if significant_digits.bytesize > DECIMAL_MAX_SIGNIFICANT_DIGITS

      bounded_decimal_result(BigDecimal(raw.tr(",", ".")))
    rescue ArgumentError
      nil
    end

    def bounded_decimal_result(value)
      return unless value.is_a?(BigDecimal) && value.finite?
      return if value.nonzero? && value.abs < DECIMAL_MIN_NONZERO_VALUE
      return if value.abs >= DECIMAL_MAX_VALUE

      value
    end

    def valid_isin?(value)
      code = value.to_s.upcase
      return false unless /\A[A-Z]{2}[A-Z0-9]{9}[0-9]\z/.match?(code)

      expanded = code.chars.map { |char| char.match?(/[A-Z]/) ? (char.ord - 55).to_s : char }.join
      digits = expanded.chars.map(&:to_i)
      sum = digits.reverse.each_with_index.sum do |digit, index|
        value = index.odd? ? digit * 2 : digit
        value.digits.sum
      end
      (sum % 10).zero?
    end
  end

  private

    def login_form(account, password, otp_code: nil)
      pairs = [ [ "USER", account.rjust(5, "0") ], [ "PASSW", password ], [ "FUNZI", "JHTJ" ] ]
      pairs << [ "FILL6", otp_code ] if otp_code
      pairs
    end

    def login_result(response, account_number:, connection_generation:, deadline:, retry_challenge_token: nil)
      begin
        ensure_success_response!(response, :authentication_failed)
        token_or_challenge = parse_contact_response(response.body)
      rescue AuthenticationError
        raise unless retry_challenge_token

        return LoginChallenge.new(
          account_number: account_number,
          challenge_token: retry_challenge_token,
          connection_generation: connection_generation
        )
      end
      return LoginChallenge.new(
        account_number: account_number,
        challenge_token: token_or_challenge.fetch(:challenge_token),
        connection_generation: connection_generation
      ) if token_or_challenge.key?(:challenge_token)

      bootstrap_verified_session(
        initial_token: token_or_challenge.fetch(:token),
        account_number: account_number,
        connection_generation: connection_generation,
        deadline: deadline
      )
    end

    def parse_contact_response(body)
      lines = body.to_s.lines.map(&:strip).reject(&:empty?)
      success_lines = lines.select { |line| line.start_with?("USER__") }
      if success_lines.one?
        token = success_lines.first.delete_prefix("USER__").strip
        validate_token!(token)
        return { token: token }
      end
      if success_lines.any?
        raise_error(AuthenticationError, :authentication_failed, "Directa authentication failed.")
      end

      payload = begin
        JSON.parse(body.to_s, max_nesting: 100)
      rescue JSON::ParserError, JSON::NestingError
        nil
      end
      user = payload.is_a?(Hash) ? payload["USER"] : nil
      otp_lines = lines.filter_map do |line|
        next unless line.start_with?("\"USER\":\"OTP_")

        suffix = line.delete_prefix("\"USER\":\"OTP_").split("\",", 2).first
        suffix if suffix.present?
      end
      challenge_token = if user.is_a?(String) && user.start_with?("OTP_")
        user.delete_prefix("OTP_")
      elsif otp_lines.one?
        otp_lines.first
      end
      if challenge_token.present? && challenge_token.bytesize <= MAX_CHALLENGE_BYTES &&
          !challenge_token.match?(/[\r\n\x00]/)
        return { challenge_token: challenge_token }
      end

      raise_error(AuthenticationError, :authentication_failed, "Directa authentication failed.")
    end

    def bootstrap_verified_session(initial_token:, account_number:, connection_generation:, deadline:)
      multi_token, mono_token = derive_tokens(initial_token)
      identity_response = @http_transport.request(
        :account_identity,
        query: { "USER" => multi_token },
        deadline: deadline,
        body_limit: 16 * 1024
      )
      ensure_success_response!(identity_response, :account_identity_unavailable)
      trading_account = identity_response.body.to_s.lines.map(&:strip).find(&:present?)
      unless account_identity_matches?(account_number, trading_account)
        raise_error(AccountIdentityMismatch, :account_identity_changed, "Directa account identity could not be verified.")
      end

      metadata_response = @http_transport.request(
        :startup_metadata,
        query: { "REQUEST" => "*", "TOKEN" => multi_token },
        deadline: deadline,
        body_limit: HTTP_BODY_LIMIT_BYTES
      )
      ensure_success_response!(metadata_response, :startup_metadata_unavailable)
      metadata = parse_json!(metadata_response.body, :startup_metadata_invalid)
      user_info = metadata.is_a?(Hash) ? metadata["userInfo"] : nil
      metadata_account = user_info.is_a?(Hash) ? identity_string(user_info["conto"]) : nil
      unless account_identity_matches?(account_number, metadata_account) &&
          account_identity_matches?(trading_account, metadata_account)
        raise_error(AccountIdentityMismatch, :account_identity_changed, "Directa account identity could not be verified.")
      end

      VerifiedSession.new(
        account_number: account_number,
        account_identity: metadata_account,
        multi_token: multi_token,
        mono_token: mono_token,
        host: HOST,
        connection_generation: connection_generation
      )
    end

    def derive_tokens(token)
      validate_token!(token)
      first = "8#{token[1]}9#{token[3..]}"
      [ first, "4#{first[1..]}" ]
    end

    def validate_token!(token)
      unless token.is_a?(String) && token.bytesize.between?(4, MAX_TOKEN_BYTES) &&
          /\A[A-Za-z0-9_-]+\z/.match?(token)
        raise_error(AuthenticationError, :authentication_failed, "Directa authentication failed.")
      end

      token
    end

    def validate_account_number!(value)
      account = value.to_s
      unless account.bytesize.between?(1, MAX_ACCOUNT_NUMBER_BYTES) && /\A[A-Za-z0-9]+\z/.match?(account)
        raise_error(ConfigurationError, :invalid_account, "Directa account number is invalid.")
      end

      account
    end

    def validate_generation!(value)
      generation = Integer(value)
      raise ArgumentError if generation.negative?

      generation
    rescue ArgumentError, TypeError
      raise_error(ConfigurationError, :invalid_generation, "Directa connection generation is invalid.")
    end

    def account_identity_matches?(expected, actual)
      expected_value = canonical_account_identity(expected)
      actual_value = canonical_account_identity(actual)
      expected_value.present? && actual_value.present? && expected_value == actual_value
    end

    def canonical_account_identity(value)
      raw = identity_string(value)
      return unless raw && /\A[A-Za-z0-9]{1,#{MAX_ACCOUNT_NUMBER_BYTES}}\z/.match?(raw)

      raw.match?(/\A[0-9]+\z/) ? raw.sub(/\A0+(?=\d)/, "") : raw.rjust(5, "0")
    end

    def identity_string(value)
      return value.strip if value.is_a?(String)
      value.to_s if value.is_a?(Integer)
    end

    def require_verified_session!
      session = @session
      unless session.is_a?(VerifiedSession) && session.host == HOST &&
          account_identity_matches?(session.account_number, session.account_identity) &&
          /\A[A-Za-z0-9_-]{4,#{MAX_TOKEN_BYTES}}\z/.match?(session.multi_token.to_s) &&
          /\A[A-Za-z0-9_-]{4,#{MAX_TOKEN_BYTES}}\z/.match?(session.mono_token.to_s) &&
          session.connection_generation >= 0
        raise_error(AuthenticationError, :session_not_verified, "Directa verified session is required.")
      end

      session
    end

    def validate_instrument_codes!(codes)
      unless codes.is_a?(Array) && codes.length <= MAX_INSTRUMENT_CODES
        raise_error(ConfigurationError, :instrument_request_invalid, "Directa instrument request is invalid.")
      end
      normalized = codes.map do |code|
        value = code.to_s
        unless value.bytesize.between?(1, MAX_INSTRUMENT_CODE_BYTES) &&
            /\A[A-Za-z0-9._-]+\z/.match?(value)
          raise_error(ConfigurationError, :instrument_request_invalid, "Directa instrument request is invalid.")
        end
        value
      end
      raise_error(ConfigurationError, :instrument_request_invalid, "Directa instrument request contains duplicates.") unless normalized.uniq.length == normalized.length

      normalized
    end

    def instrument_metadata_query(token, codes)
      {
        "JSON" => "Y",
        "CODPREZZI" => "Y",
        "TOKEN" => token,
        "TITOLI" => codes.join(";"),
        "ATTRIBUTI" => "*ALL"
      }
    end

    def parse_instrument_metadata(payload, requested_codes)
      unless payload.is_a?(Hash) && payload["titoli"].is_a?(Array)
        raise_error(InvalidResponse, :metadata_response_invalid, "Directa instrument metadata response is invalid.")
      end
      records = payload.fetch("titoli")
      if records.length > MAX_INSTRUMENT_CODES
        raise_error(ResponseTooLarge, :metadata_response_too_large, "Directa instrument metadata response is too large.")
      end

      instruments = {}
      records.each do |record|
        next unless record.is_a?(Hash)

        requested_code = bounded_string(record["CodiceRichiesto"], MAX_INSTRUMENT_CODE_BYTES)
        next unless requested_codes.include?(requested_code)
        if instruments.key?(requested_code)
          raise_error(InvalidResponse, :duplicate_instrument_metadata, "Directa returned duplicate instrument metadata.")
        end

        isin = bounded_string(record["Isin"], 12)&.upcase
        isin = nil unless self.class.valid_isin?(isin)
        currency = bounded_string(record["Divisa"], 3)&.upcase
        currency = nil unless currency && /\A[A-Z]{3}\z/.match?(currency)
        raw_multiplier = bounded_numeric_text(record["Moltip"], 32)
        raw_tick_size = bounded_numeric_text(record["TickFisso"], 32)
        raw_reference_price = bounded_numeric_text(record["PrzRif"], 32)
        instruments[requested_code] = InstrumentMetadata.new(
          requested_code: requested_code,
          canonical_code: bounded_string(record["Codice"], MAX_INSTRUMENT_CODE_BYTES),
          isin: isin,
          currency: currency,
          description: bounded_string(record["Descriz"], 256),
          directa_market: bounded_string(record["MercNeg"], 32),
          directa_segment: bounded_string(record["Segmento"], 32),
          multiplier: self.class.parse_decimal(raw_multiplier),
          raw_multiplier: raw_multiplier,
          price_codes: bounded_string_array(record["CodPrezzi"], 32),
          tick_table: bounded_string(record["TabTick"], 32),
          tick_size: self.class.parse_decimal(raw_tick_size),
          raw_tick_size: raw_tick_size,
          identity_status: isin ? :partial : :unresolved,
          field_sources: FIELD_SOURCES,
          phase: bounded_string(record["TFase"], 8),
          instrument_type: bounded_instrument_type(record["TTipo"]),
          authorization_markets: authorization_markets(record["MercAbilitazioni"]),
          reference_price: self.class.parse_decimal(raw_reference_price)
        )
      end

      InstrumentMetadataResult.new(
        instruments: instruments,
        missing_codes: requested_codes - instruments.keys
      )
    end

    def bounded_string(value, max_bytes)
      return unless value.is_a?(String)

      string = value.strip
      return if string.empty? || string.bytesize > max_bytes || string.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F]/)

      string
    end

    def bounded_string_array(value, max_item_bytes)
      return [] unless value.is_a?(Array) && value.length <= 64

      value.filter_map { |item| bounded_string(item, max_item_bytes) }
    end

    def bounded_numeric_text(value, max_bytes)
      return unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal)
      return if value.is_a?(Float) && !value.finite?

      raw = value.to_s.strip
      return if raw.empty? || raw.bytesize > max_bytes

      raw
    end

    def bounded_instrument_type(value)
      return unless value.is_a?(String)
      return "" if value.empty?

      bounded_string(value, 8)
    end

    def authorization_markets(value)
      return [] unless value.is_a?(Array) && value.length.between?(1, 16)
      return [] unless value.all? { |market| market.is_a?(String) && market.bytesize == 1 && market.match?(/\A[A-Za-z]\z/) }
      return [] unless value.uniq.length == value.length

      value
    end

    def ensure_success_response!(response, failure_code)
      return if response.status == 200
      if response.status.between?(300, 399)
        raise_error(RedirectRejected, :redirect_rejected, "Directa redirected a read request.")
      end
      if response.status == 401 || response.status == 403
        raise_error(AuthenticationError, :authentication_failed, "Directa authentication failed.")
      end
      if response.status == 429
        raise_error(ProviderUnavailable, :rate_limited, "Directa request was rate limited.")
      end

      klass = response.status >= 500 ? ProviderUnavailable : InvalidResponse
      raise_error(klass, failure_code, "Directa returned an unexpected response.")
    end

    def enrich_snapshot_metadata(snapshot, verified_session, deadline:)
      return snapshot if snapshot.positions.empty?

      codes = snapshot.positions.map(&:univoco)
      response = @http_transport.request(
        :instrument_metadata,
        query: instrument_metadata_query(verified_session.multi_token, validate_instrument_codes!(codes)),
        deadline: deadline,
        body_limit: HTTP_BODY_LIMIT_BYTES
      )
      ensure_success_response!(response, :metadata_request_failed)
      metadata = parse_instrument_metadata(parse_json!(response.body, :metadata_response_invalid), codes)
      startup_tables = fetch_startup_tables(verified_session, deadline: deadline)
      enriched_positions = snapshot.positions.map do |position|
        instrument = metadata.instruments[position.univoco]
        Position.new(
          univoco: position.univoco,
          quantity: position.quantity,
          raw_quantity: position.raw_quantity,
          raw_average_price: position.raw_average_price,
          raw_fields: position.raw_fields,
          instrument_metadata: instrument,
          field_sources: position.field_sources
        )
      end

      enriched_snapshot = Snapshot.new(
        account_number: snapshot.account_number,
        account_identity: snapshot.account_identity,
        connection_generation: snapshot.connection_generation,
        observed_at: snapshot.observed_at,
        cash_seen: snapshot.cash_seen,
        positions_complete: snapshot.positions_complete,
        full_photo_complete: snapshot.full_photo_complete,
        cash: snapshot.cash,
        positions: enriched_positions,
        unknown_message_types: snapshot.unknown_message_types,
        field_sources: snapshot.field_sources
      )
      ObservedValuation.new(tables: startup_tables).apply(enriched_snapshot)
    end

    def fetch_startup_tables(verified_session, deadline:)
      response = @http_transport.request(
        :startup_metadata,
        query: { "REQUEST" => "*", "TOKEN" => verified_session.multi_token },
        deadline: deadline,
        body_limit: HTTP_BODY_LIMIT_BYTES
      )
      ensure_success_response!(response, :startup_metadata_unavailable)
      payload = parse_json!(response.body, :startup_metadata_invalid)
      unless payload.is_a?(Hash) && payload["userInfo"].is_a?(Hash)
        raise_error(InvalidResponse, :startup_metadata_invalid, "Directa startup metadata is invalid.")
      end

      metadata_account = identity_string(payload.dig("userInfo", "conto"))
      unless account_identity_matches?(verified_session.account_number, metadata_account) &&
          account_identity_matches?(verified_session.account_identity, metadata_account)
        raise_error(AccountIdentityMismatch, :account_identity_changed, "Directa startup account identity could not be verified.")
      end

      observed_at = Time.current
      data = payload["dataStruct"].is_a?(Hash) ? payload["dataStruct"] : {}
      ObservedValuation::ValuationTables.new(
        market_authorizations: ObservedValuation.market_authorizations(data["mercati"]),
        fx_rates: ObservedValuation.fx_rates(data["cambi"]),
        fx_observed_at: observed_at
      )
    end

    def parse_json!(body, failure_code)
      JSON.parse(body.to_s, max_nesting: 100)
    rescue JSON::ParserError, JSON::NestingError
      raise_error(InvalidResponse, failure_code, "Directa returned an invalid response.")
    end

    def with_deadline
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REQUEST_TIMEOUT_SECONDS
      yield deadline
    rescue HttpTransport::RequestTimeout, TradingConnection::RequestTimeout
      raise_error(RequestTimeout, :request_timeout, "Directa request timed out.")
    end

    def raise_error(klass, code, message)
      raise klass.new(message, failure_code: code), cause: nil
    end
end

require_relative "directa/http_transport"
require_relative "directa/trading_connection"
require_relative "directa/observed_valuation"
