# frozen_string_literal: true

require "date"
require "json"

class Provider::Directa
  class History
    MIN_DATE = Date.new(2018, 1, 1)
    BANK_TIME_ZONE = "Europe/Rome".freeze
    PAGE_SIZE = 100
    MAX_PAGES = 50
    MAX_ROWS = 5_000
    MAX_ROW_FIELDS = 64
    MAX_ROW_KEY_BYTES = 64
    MAX_ROW_VALUE_BYTES = 2_048
    TOTAL_TIMEOUT_SECONDS = 120
    STATEMENT_BODY_LIMIT_BYTES = 2 * 1024 * 1024

    SessionScope = Data.define(:account_number, :account_identity, :connection_generation) do
      def initialize(account_number:, account_identity:, connection_generation:)
        super(
          account_number: account_number.to_s.dup.freeze,
          account_identity: account_identity.to_s.dup.freeze,
          connection_generation: Integer(connection_generation)
        )
      end

      def inspect
        "#<#{self.class.name}: verified generation=#{connection_generation}>"
      end
      alias to_s inspect
    end

    OrdersResult = Data.define(:scope, :date_from, :date_to, :orders, :complete, :fetched_at) do
      def initialize(scope:, date_from:, date_to:, orders:, complete:, fetched_at:)
        super(
          scope: scope,
          date_from: date_from,
          date_to: date_to,
          orders: orders.freeze,
          complete: complete,
          fetched_at: fetched_at
        )
      end

      def inspect
        "#<#{self.class.name}: complete=#{complete} rows=#{orders.length}>"
      end
      alias to_s inspect
    end

    StatementResult = Data.define(:scope, :date, :body, :source_encoding, :fetched_at) do
      def initialize(scope:, date:, body:, source_encoding:, fetched_at:)
        super(
          scope: scope,
          date: date,
          body: body.b.dup.freeze,
          source_encoding: source_encoding,
          fetched_at: fetched_at
        )
      end

      def inspect
        "#<#{self.class.name}: date=#{date} bytes=#{body.bytesize}>"
      end
      alias to_s inspect
    end

    def initialize(session:, http_transport: HttpTransport.new)
      @session = session
      @http_transport = http_transport
      @session_validator = Provider::Directa.new(session: session, http_transport: http_transport)
    end

    def fetch_orders(date_from:, date_to:)
      from = normalize_date!(date_from)
      to = normalize_date!(date_to)
      validate_date_range!(from, to)
      session = require_verified_session!
      scope = session_scope(session)

      with_deadline do |deadline|
        verify_session_identity!(session, deadline: deadline)
        orders = fetch_order_pages(session, from: from, to: to, deadline: deadline)
        verify_session_identity!(session, deadline: deadline)

        OrdersResult.new(
          scope: scope,
          date_from: from,
          date_to: to,
          orders: orders,
          complete: true,
          fetched_at: Time.current
        )
      end
    rescue Provider::Directa::Error
      raise
    rescue StandardError
      raise_provider_error(Provider::Directa::ProviderUnavailable, :provider_unavailable, "Directa order history is unavailable.")
    end

    def fetch_statement(date:)
      statement_date = normalize_date!(date)
      validate_single_date!(statement_date)
      session = require_verified_session!
      scope = session_scope(session)

      with_deadline do |deadline|
        verify_session_identity!(session, deadline: deadline)
        response = @http_transport.request(
          :account_statement,
          query: {
            "USER" => session.mono_token,
            "TPGE" => "A00",
            "DATE" => statement_date.strftime("%d%m%Y"),
            "TIPOUT" => "MAC"
          },
          deadline: deadline,
          body_limit: STATEMENT_BODY_LIMIT_BYTES
        )
        @session_validator.send(:ensure_success_response!, response, :statement_request_failed)
        unless response.body.is_a?(String) && response.body.bytesize <= STATEMENT_BODY_LIMIT_BYTES
          raise_provider_error(Provider::Directa::ResponseTooLarge, :response_too_large, "Directa account statement exceeded the size limit.")
        end
        verify_session_identity!(session, deadline: deadline)

        StatementResult.new(
          scope: scope,
          date: statement_date,
          body: response.body,
          source_encoding: Encoding::ISO_8859_1,
          fetched_at: Time.current
        )
      end
    rescue Provider::Directa::Error
      raise
    rescue StandardError
      raise_provider_error(Provider::Directa::ProviderUnavailable, :provider_unavailable, "Directa account statement is unavailable.")
    end

    private

      def require_verified_session!
        @session_validator.send(:require_verified_session!)
      end

      def session_scope(session)
        SessionScope.new(
          account_number: session.account_number,
          account_identity: session.account_identity,
          connection_generation: session.connection_generation
        )
      end

      def fetch_order_pages(session, from:, to:, deadline:)
        orders = []
        references = {}
        offset = 0
        page_count = 0

        loop do
          ensure_time_remaining!(deadline)
          if page_count >= MAX_PAGES
            raise_provider_error(Provider::Directa::ResponseTooLarge, :history_limit_exceeded, "Directa order history exceeded the retrieval limit.")
          end

          response = @http_transport.request(
            :executed_orders,
            query: {
              "TOKEN" => session.multi_token,
              "TIPO" => "E",
              "RCDDA" => offset.to_s,
              "NRCD" => (PAGE_SIZE - 1).to_s,
              "DATADA" => from.strftime("%Y%m%d"),
              "DATAA" => to.strftime("%Y%m%d")
            },
            deadline: deadline,
            body_limit: STATEMENT_BODY_LIMIT_BYTES
          )
          @session_validator.send(:ensure_success_response!, response, :history_request_failed)
          payload = @session_validator.send(:parse_json!, response.body, :history_response_invalid)
          unless payload.is_a?(Hash) && payload.keys == [ "ORDER" ] && payload["ORDER"].is_a?(Array)
            raise_provider_error(Provider::Directa::InvalidResponse, :history_response_invalid, "Directa returned an invalid order history page.")
          end

          page = payload.fetch("ORDER")
          if page.length > PAGE_SIZE
            raise_provider_error(Provider::Directa::ResponseTooLarge, :history_page_too_large, "Directa returned an oversized order history page.")
          end
          break if page.empty?
          if orders.length + page.length > MAX_ROWS
            raise_provider_error(Provider::Directa::ResponseTooLarge, :history_limit_exceeded, "Directa order history exceeded the retrieval limit.")
          end

          page.each_with_index do |row, index|
            validate_order_row!(row, expected_row: offset + index + 1, from: from, to: to, references: references)
            orders << deep_freeze_json(row)
          end

          offset += page.length
          page_count += 1
        end

        orders.freeze
      end

      def validate_order_row!(row, expected_row:, from:, to:, references:)
        unless row.is_a?(Hash) && row.length <= MAX_ROW_FIELDS &&
            row.all? { |key, value| key.is_a?(String) && key.bytesize <= MAX_ROW_KEY_BYTES && safe_row_value?(value) }
          raise_provider_error(Provider::Directa::InvalidResponse, :history_row_invalid, "Directa returned an invalid order history row.")
        end

        row_number = row["Row"]
        row_number = row_number.to_i if row_number.is_a?(String) && /\A[0-9]{1,10}\z/.match?(row_number)
        unless row_number.is_a?(Integer) && row_number == expected_row
          raise_provider_error(Provider::Directa::InvalidResponse, :history_sequence_invalid, "Directa order history pagination is inconsistent.")
        end

        reference = row["Riferimento"]
        unless reference.is_a?(String) && reference.present? && reference.bytesize <= MAX_ROW_VALUE_BYTES && reference == reference.strip
          raise_provider_error(Provider::Directa::InvalidResponse, :history_reference_invalid, "Directa returned an invalid order reference.")
        end
        if references.key?(reference)
          raise_provider_error(Provider::Directa::InvalidResponse, :duplicate_history_reference, "Directa returned a duplicate order reference.")
        end
        references[reference] = true

        event_date = parse_row_date!(row["DataEvento"])
        unless event_date.between?(from, to)
          raise_provider_error(Provider::Directa::InvalidResponse, :history_date_out_of_range, "Directa returned an order outside the requested date range.")
        end
        parse_row_date!(row["DataImmissione"]) if row.key?("DataImmissione") && !row["DataImmissione"].nil?
      end

      def safe_row_value?(value)
        case value
        when String
          value.bytesize <= MAX_ROW_VALUE_BYTES
        when Integer, Float, TrueClass, FalseClass, NilClass
          !value.is_a?(Float) || value.finite?
        else
          false
        end
      end

      def parse_row_date!(value)
        raw = value.to_s
        unless (value.is_a?(Integer) || value.is_a?(String)) && /\A[0-9]{8}\z/.match?(raw)
          raise_provider_error(Provider::Directa::InvalidResponse, :history_date_invalid, "Directa returned an invalid order date.")
        end

        Date.strptime(raw, "%Y%m%d")
      rescue Date::Error
        raise_provider_error(Provider::Directa::InvalidResponse, :history_date_invalid, "Directa returned an invalid order date.")
      end

      def deep_freeze_json(value)
        case value
        when Hash
          value.each do |key, item|
            key.freeze
            deep_freeze_json(item)
          end
          value.freeze
        when Array
          value.each { |item| deep_freeze_json(item) }
          value.freeze
        when String
          value.freeze
        else
          value
        end
      end

      def verify_session_identity!(session, deadline:)
        identity_response = @http_transport.request(
          :account_identity,
          query: { "USER" => session.multi_token },
          deadline: deadline,
          body_limit: 16 * 1024
        )
        @session_validator.send(:ensure_success_response!, identity_response, :account_identity_unavailable)
        trading_account = identity_response.body.to_s.lines.map(&:strip).find(&:present?)
        unless identity_matches_session?(session, trading_account)
          raise_provider_error(Provider::Directa::AccountIdentityMismatch, :account_identity_changed, "Directa account identity could not be verified.")
        end

        metadata_response = @http_transport.request(
          :startup_metadata,
          query: { "REQUEST" => "*", "TOKEN" => session.multi_token },
          deadline: deadline,
          body_limit: Provider::Directa::HTTP_BODY_LIMIT_BYTES
        )
        @session_validator.send(:ensure_success_response!, metadata_response, :startup_metadata_unavailable)
        metadata = @session_validator.send(:parse_json!, metadata_response.body, :startup_metadata_invalid)
        user_info = metadata.is_a?(Hash) ? metadata["userInfo"] : nil
        metadata_account = user_info.is_a?(Hash) ? @session_validator.send(:identity_string, user_info["conto"]) : nil
        unless identity_matches_session?(session, metadata_account) &&
            @session_validator.send(:account_identity_matches?, trading_account, metadata_account)
          raise_provider_error(Provider::Directa::AccountIdentityMismatch, :account_identity_changed, "Directa account identity could not be verified.")
        end
      end

      def identity_matches_session?(session, identity)
        @session_validator.send(:account_identity_matches?, session.account_number, identity) &&
          @session_validator.send(:account_identity_matches?, session.account_identity, identity)
      end

      def normalize_date!(value)
        return value if value.instance_of?(Date)
        if value.is_a?(String) && /\A[0-9]{8}\z/.match?(value)
          return Date.strptime(value, "%Y%m%d")
        end

        raise_provider_error(Provider::Directa::ConfigurationError, :invalid_history_date, "Directa history date is invalid.")
      rescue Date::Error
        raise_provider_error(Provider::Directa::ConfigurationError, :invalid_history_date, "Directa history date is invalid.")
      end

      def validate_date_range!(from, to)
        validate_single_date!(from)
        validate_single_date!(to)
        if from > to
          raise_provider_error(Provider::Directa::ConfigurationError, :invalid_history_range, "Directa history date range is invalid.")
        end
      end

      def validate_single_date!(date)
        bank_today = Time.current.in_time_zone(BANK_TIME_ZONE).to_date
        unless date >= MIN_DATE && date < bank_today
          raise_provider_error(Provider::Directa::ConfigurationError, :invalid_history_date, "Directa history date is outside the supported range.")
        end
      end

      def with_deadline
        deadline = monotonic_time + TOTAL_TIMEOUT_SECONDS
        yield deadline
      rescue HttpTransport::RequestTimeout, Timeout::Error
        raise_provider_error(Provider::Directa::RequestTimeout, :request_timeout, "Directa history request timed out.")
      end

      def ensure_time_remaining!(deadline)
        return if deadline > monotonic_time

        raise HttpTransport::RequestTimeout, cause: nil
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def raise_provider_error(error_class, failure_code, message)
        raise error_class.new(message, failure_code: failure_code), cause: nil
      end
  end
end
