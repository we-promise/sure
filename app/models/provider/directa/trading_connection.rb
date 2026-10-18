# frozen_string_literal: true

class Provider::Directa
  class TradingConnection
    MAX_STREAM_LINE_BYTES = 16 * 1024
    MAX_STREAM_FIELDS = 256
    MAX_FIELD_BYTES = 2 * 1024
    MAX_SNAPSHOT_WIRE_BYTES = 2 * 1024 * 1024
    MAX_SNAPSHOT_RECORDS = 10_000
    MAX_UNKNOWN_MESSAGE_TYPES = 64
    HEARTBEAT_INTERVAL_SECONDS = 10
    HEARTBEAT_TIMEOUT_SECONDS = 14
    KNOWN_NON_SNAPSHOT_TYPES = [ 40, 61, 69, 79 ].freeze

    class RequestTimeout < StandardError; end

    def initialize(session:, transport_factory: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @session = session
      @clock = clock
      @transport_factory = transport_factory || ->(deadline:) { TlsTransport.new(deadline: deadline) }
      @last_sequence = 0
    end

    def fetch_snapshot(deadline:)
      validate_session!
      @transport = @transport_factory.call(deadline: deadline)
      send_line("21#{@session.multi_token}ND\r\n", deadline: deadline)
      login_line = @transport.read_line(timeout: remaining(deadline))
      raise RequestTimeout, cause: nil unless login_line
      login_fields = parse_login_record(login_line)
      unless login_fields.length == 6 && login_fields[4] == @session.multi_token
        raise AuthenticationError.new("Directa trading login failed.", failure_code: :authentication_failed)
      end

      send_line("70\r\n", deadline: deadline)
      read_snapshot(deadline)
    rescue RequestTimeout
      raise
    rescue Error
      raise
    rescue Timeout::Error
      raise RequestTimeout, cause: nil
    rescue SocketError, SystemCallError, EOFError, IOError, OpenSSL::SSL::SSLError
      raise ProviderUnavailable.new("Directa trading connection failed.", failure_code: :provider_unavailable), cause: nil
    ensure
      @transport&.close
      @transport = nil
    end

    private

      def read_snapshot(deadline)
        cash = nil
        cash_seen = false
        positions = []
        position_codes = {}
        unknown_types = []
        stream_bytes = 0
        stream_records = 0
        positions_complete = false
        full_photo_complete = false
        next_heartbeat_at = @clock.call + HEARTBEAT_INTERVAL_SECONDS
        heartbeat_sent_at = nil

        loop do
          now = @clock.call
          raise RequestTimeout, cause: nil if now >= deadline
          if heartbeat_sent_at && now - heartbeat_sent_at >= HEARTBEAT_TIMEOUT_SECONDS
            raise RequestTimeout, cause: nil
          end

          wait_limits = [ remaining(deadline), [ next_heartbeat_at - now, 0 ].max ]
          if heartbeat_sent_at
            wait_limits << [ heartbeat_sent_at + HEARTBEAT_TIMEOUT_SECONDS - now, 0 ].max
          end
          wait_seconds = wait_limits.min
          line = @transport.read_line(timeout: wait_seconds)
          unless line
            now = @clock.call
            if now >= next_heartbeat_at
              if heartbeat_sent_at.nil?
                send_line("40\r\n", deadline: deadline)
                heartbeat_sent_at = now
              end
              next_heartbeat_at = now + HEARTBEAT_INTERVAL_SECONDS
            end
            next
          end

          stream_bytes += line.bytesize
          stream_records += 1
          if stream_bytes > MAX_SNAPSHOT_WIRE_BYTES || stream_records > MAX_SNAPSHOT_RECORDS
            raise ResponseTooLarge.new("Directa snapshot exceeded the stream limit.", failure_code: :snapshot_too_large)
          end
          fields, type = parse_record(line)
          case type
          when 40
            heartbeat_sent_at = nil
          when 60
            cash = parse_cash(fields)
            cash_seen = true
          when 61
            nil
          when 69
            full_photo_complete = true
          when 70
            position = parse_position(fields)
            if position_codes.key?(position.univoco)
              raise InvalidResponse.new("Directa returned a duplicate position.", failure_code: :duplicate_position)
            end
            if positions.length >= MAX_SNAPSHOT_POSITIONS
              raise ResponseTooLarge.new("Directa snapshot exceeded the position limit.", failure_code: :snapshot_too_large)
            end
            position_codes[position.univoco] = true
            positions << position
          when 79
            positions_complete = true
          when 99
            raise ProviderUnavailable.new("Directa trading connection reported an error.", failure_code: :provider_unavailable)
          when 93
            raise AuthenticationError.new("Directa trading session expired.", failure_code: :session_expired)
          else
            unless KNOWN_NON_SNAPSHOT_TYPES.include?(type) || unknown_types.include?(type)
              unknown_types << type
              if unknown_types.length > MAX_UNKNOWN_MESSAGE_TYPES
                raise ResponseTooLarge.new("Directa snapshot contained too many unknown message types.", failure_code: :snapshot_too_large)
              end
            end
          end

          break if cash_seen && positions_complete
        end

        Snapshot.new(
          account_number: @session.account_number,
          account_identity: @session.account_identity,
          connection_generation: @session.connection_generation,
          observed_at: Time.now.utc,
          cash_seen: cash_seen,
          positions_complete: positions_complete,
          full_photo_complete: full_photo_complete,
          cash: cash,
          positions: positions,
          unknown_message_types: unknown_types
        )
      end

      def parse_record(line)
        raw = line.to_s
        if raw.empty? || raw.bytesize > MAX_STREAM_LINE_BYTES || raw.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F]/)
          raise StreamProtocolError.new("Directa sent an invalid trading record.", failure_code: :invalid_record)
        end

        fields = raw.split(";", -1)
        if fields.length > MAX_STREAM_FIELDS || fields.any? { |field| field.bytesize > MAX_FIELD_BYTES }
          raise ResponseTooLarge.new("Directa trading record exceeded the field limit.", failure_code: :record_too_large)
        end
        unless /\A\d+\z/.match?(fields[0].to_s)
          raise SequenceError.new("Directa trading sequence is invalid.", failure_code: :invalid_sequence)
        end

        sequence = Integer(fields[0], 10)
        unless sequence == @last_sequence + 1
          raise SequenceError.new("Directa trading sequence is out of order.", failure_code: :sequence_mismatch)
        end
        @last_sequence = sequence
        unless fields[1].to_s.match?(/\A\d+\z/) && fields[2].to_s.match?(/\A\d+\z/)
          raise StreamProtocolError.new("Directa trading message type is invalid.", failure_code: :invalid_message_type)
        end

        [ fields, Integer("#{fields[1]}#{fields[2]}", 10) ]
      rescue ArgumentError
        raise StreamProtocolError.new("Directa trading record is invalid.", failure_code: :invalid_record)
      end

      def parse_login_record(line)
        raw = line.to_s
        if raw.empty? || raw.bytesize > MAX_STREAM_LINE_BYTES || raw.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F]/)
          raise StreamProtocolError.new("Directa sent an invalid login record.", failure_code: :invalid_record)
        end

        fields = raw.split(";", -1)
        fields.pop while fields.length > 6 && fields.last.empty?
        if fields.length != 6 || fields.any? { |field| field.bytesize > MAX_FIELD_BYTES } ||
            !/\A\d+\z/.match?(fields[0].to_s)
          raise AuthenticationError.new("Directa trading login failed.", failure_code: :authentication_failed)
        end

        sequence = Integer(fields[0], 10)
        unless sequence == @last_sequence + 1
          raise SequenceError.new("Directa trading sequence is out of order.", failure_code: :sequence_mismatch)
        end
        @last_sequence = sequence
        fields
      rescue ArgumentError
        raise AuthenticationError.new("Directa trading login failed.", failure_code: :authentication_failed)
      end

      def parse_cash(fields)
        if fields.length <= 7
          raise StreamProtocolError.new("Directa cash record is incomplete.", failure_code: :cash_record_invalid)
        end
        raw_amount = fields[7]
        Cash.new(
          amount: Provider::Directa.parse_cash_amount(raw_amount),
          raw_amount: raw_amount,
          equity_availability: fields[3],
          equity_margin_availability: fields[5],
          realtime_availability: fields[9],
          consolidated_performance: fields[8],
          raw_fields: fields,
          field_sources: FIELD_SOURCES
        )
      end

      def parse_position(fields)
        unless fields.length > 9 && fields[5].present? && fields[5].bytesize <= MAX_FIELD_BYTES
          raise StreamProtocolError.new("Directa position record is incomplete.", failure_code: :position_record_invalid)
        end

        raw_quantity = fields[9]
        quantity = Integer(raw_quantity, 10) if /\A[+-]?\d+\z/.match?(raw_quantity)
        Position.new(
          univoco: fields[5],
          quantity: quantity,
          raw_quantity: raw_quantity,
          raw_average_price: fields[10],
          raw_fields: fields,
          field_sources: FIELD_SOURCES
        )
      rescue ArgumentError
        raise StreamProtocolError.new("Directa position quantity is invalid.", failure_code: :position_quantity_invalid)
      end

      def send_line(command, deadline:)
        allowed = command.start_with?("21") && command.end_with?("ND\r\n") ||
          [ "70\r\n", "40\r\n" ].include?(command)
        unless allowed
          raise ConfigurationError.new("Directa trading command is not allowed.", failure_code: :command_not_allowed)
        end

        @transport.write(command, deadline: deadline)
      end

      def validate_session!
        unless @session.is_a?(VerifiedSession) && @session.host == HOST &&
            @session.account_number.present? && @session.account_identity.present? &&
            /\A[A-Za-z0-9_-]{4,#{MAX_TOKEN_BYTES}}\z/.match?(@session.multi_token.to_s) &&
            /\A[A-Za-z0-9_-]{4,#{MAX_TOKEN_BYTES}}\z/.match?(@session.mono_token.to_s)
          raise AuthenticationError.new("Directa verified session is required.", failure_code: :session_not_verified)
        end
      end

      def remaining(deadline)
        value = deadline.to_f - @clock.call
        raise RequestTimeout, cause: nil unless value.positive?

        value
      end

      class TlsTransport
        def initialize(deadline:)
          @buffer = +"".b
          remaining = remaining_until(deadline)
          @tcp = Timeout.timeout(remaining, RequestTimeout) do
            Socket.tcp(
              HOST,
              TRADING_PORT,
              connect_timeout: remaining,
              resolv_timeout: remaining
            )
          end
          context = OpenSSL::SSL::SSLContext.new
          context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
          @socket = OpenSSL::SSL::SSLSocket.new(@tcp, context)
          @socket.hostname = HOST
          @socket.sync_close = true
          Timeout.timeout(remaining_until(deadline), RequestTimeout) { @socket.connect }
          @socket.post_connection_check(HOST)
        rescue RequestTimeout
          close
          raise
        rescue Timeout::Error
          close
          raise RequestTimeout, cause: nil
        rescue Errno::ETIMEDOUT
          close
          raise RequestTimeout, cause: nil
        rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError
          close
          raise
        end

        def write(value, deadline:)
          data = value.to_s.b
          offset = 0
          while offset < data.bytesize
            Timeout.timeout(deadline - monotonic, RequestTimeout) do
              offset += @socket.write(data.byteslice(offset, data.bytesize - offset))
            end
          end
        rescue Timeout::Error
          raise RequestTimeout, cause: nil
        end

        def read_line(timeout:)
          deadline = monotonic + timeout
          loop do
            if (line_end = @buffer.index("\n".b))
              line = @buffer.slice!(0, line_end + 1).delete_suffix("\n".b).delete_suffix("\r".b)
              return line.force_encoding(Encoding::UTF_8)
            end
            if @buffer.bytesize >= MAX_STREAM_LINE_BYTES
              raise ResponseTooLarge.new("Directa trading record exceeded the line limit.", failure_code: :record_too_large)
            end
            remaining = deadline - monotonic
            return nil unless remaining.positive?
            readable = @socket.pending.positive? || IO.select([ @socket ], nil, nil, remaining)
            return nil unless readable

            begin
              @buffer << @socket.read_nonblock(4 * 1024)
            rescue IO::WaitReadable
              next
            rescue IO::WaitWritable
              next unless IO.select(nil, [ @socket ], nil, deadline - monotonic)
            rescue EOFError
              raise
            end
          end
        end

        def close
          @socket&.close
          @tcp&.close unless @tcp&.closed?
        rescue IOError
          nil
        ensure
          @socket = nil
          @tcp = nil
        end

        private

          def monotonic
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def remaining_until(deadline)
            remaining = deadline - monotonic
            raise RequestTimeout, cause: nil unless remaining.positive?

            remaining
          end
      end
  end
end
