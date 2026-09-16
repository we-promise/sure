require "json"

# Routing projected from the immutable command, never from today's account link
# or selected policies. An empty historical binding remains explicitly unknown.
class Ingestion::HistoricalBalances::SourceBinding
  FORMAT = "historical-command/v1".freeze
  STREAMS = %w[historical_balances opening_anchor_repairs].freeze
  MAX_STORED_BYTES = 48 * 1024 * 1024
  MAX_CONTEXT_BYTES = 32 * 1024 * 1024
  MAX_BINDING_BYTES = 16 * 1024
  MAX_NODES = 1_000_000
  MAX_DEPTH = 64
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  HEADERS = %w[id family_id origin_kind provider_connection_id external_account_id sync_id provider_sync_type
    stream scope_key source_policy_version writer_epoch schema_version mode complete import_id account_statement_id
    provider_authorization_id provider_sync_generation_id generation_role generation_resource].freeze
  Page = Data.define(:processed, :next_cursor, :complete)

  class Conflict < Provider::AccountData::InvalidResponse; end
  class Incomplete < Provider::AccountData::IncompletePage; end
  class Busy < Provider::AccountData::IncompletePage; end

  class << self
    def capture(command:)
      raise Conflict, "Expected an original historical command" unless command.is_a?(Ingestion::HistoricalBalances::Command)
      validate_payload_bound!(command.payload)
      projection(command)
    end

    def verify!(batch:)
      resolve_reference(batch, write: false)
    end

    # The caller's AR instance is not changed. Call reload before subsequently
    # saving that instance; the only database update here is source_binding.
    def index!(batch:)
      resolve_reference(batch, write: true)
    end

    def unindexed(family_id:)
      raise ArgumentError, "Expected a family identity" unless uuid?(family_id)
      historical.where(family_id: family_id, source_binding: {})
    end

    def assert_complete_for!(family_id:)
      if unindexed(family_id: family_id).exists?
        raise Incomplete, "Historical command routing requires reverse indexing"
      end
      true
    end

    def backfill_page(family_id:, after_id: nil, limit: 25)
      unless uuid?(family_id) && (after_id.nil? || uuid?(after_id)) && limit.is_a?(Integer) && (1..100).cover?(limit)
        raise ArgumentError, "Invalid historical command index page"
      end
      unless IngestionBatch.connection.open_transactions.zero?
        raise Conflict, "Historical command backfill must start outside a transaction"
      end
      ApplicationRecord.uncached do
        scope = unindexed(family_id: family_id)
        scope = scope.where("id > ?", after_id) if after_id
        ids = scope.order(:id).limit(limit + 1).pluck(:id)
        ids.first(limit).each { |id| resolve(id, family_id, write: true) }
        Page.new(processed: ids.first(limit).size, next_cursor: ids.size > limit ? ids[limit - 1] : nil, complete: ids.size <= limit)
      end
    rescue Conflict, Incomplete, Busy => error
      report_failure(error, family_id: family_id, after_id: after_id)
      raise
    end

    private
      def historical = IngestionBatch.where(origin_kind: "provider", stream: STREAMS)
      def uuid?(value) = value.is_a?(String) && value.match?(UUID)

      def projection(command)
        %i[account_id family_id account_provider_id external_account_id provider_connection_id source_batch_id source_policy_version].each do |key|
          raise Conflict, "Historical command has an invalid captured identity" unless uuid?(command[key])
        end
        %i[balance_policy_version anchor_policy_version].each do |key|
          unless command[key].nil? || uuid?(command[key])
            raise Conflict, "Historical command has an invalid captured policy"
          end
        end
        Provider::AccountData::MigrationManifest.copy_value({
          "format" => FORMAT, "account_id" => command[:account_id], "account_provider_id" => command[:account_provider_id],
          "external_account_id" => command[:external_account_id], "resource" => command.stream,
          "source_policy_version" => command[:source_policy_version], "publication" => "ledger",
          "balance_policy_version" => command[:balance_policy_version], "anchor_policy_version" => command[:anchor_policy_version],
          "source_batch_id" => command[:source_batch_id]
        })
      end

      def resolve_reference(batch, write:)
        unless batch.is_a?(IngestionBatch) && batch.persisted? && uuid?(batch.id) && uuid?(batch.family_id)
          raise Conflict, "Expected a persisted historical command batch"
        end
        resolve(batch.id, batch.family_id, write: write)
      end

      def resolve(id, family_id, write:)
        ApplicationRecord.uncached do
          IngestionBatch.transaction(requires_new: true) do
            scope = historical.where(id: id, family_id: family_id)
            header = scope.select(*HEADERS, "octet_length(payload) AS payload_bytes",
              "octet_length(source_binding::text) AS binding_bytes")
              .lock(write ? "FOR UPDATE NOWAIT" : "FOR SHARE NOWAIT").first!
            unless header.payload_bytes.is_a?(Integer) && header.payload_bytes.positive? && header.payload_bytes <= MAX_STORED_BYTES &&
                header.binding_bytes.is_a?(Integer) && header.binding_bytes <= MAX_BINDING_BYTES
              raise Conflict, "Historical command exceeds its stored byte bound"
            end
            captured = scope.where("octet_length(payload) BETWEEN 1 AND ? AND octet_length(source_binding::text) <= ?", MAX_STORED_BYTES, MAX_BINDING_BYTES)
              .select(:id, :payload, :source_binding).first!
            payload = captured.payload
            validate_payload_bound!(payload)
            command = Ingestion::HistoricalBalances::Command.load(payload)
            validate_header!(header, command)
            expected = projection(command)
            if captured.source_binding == {}
              raise Conflict, "Historical command requires reverse indexing" unless write
              captured.update_columns(source_binding: expected)
            elsif captured.source_binding != expected
              raise Conflict, "Historical command routing differs from its original capture"
            end
            expected
          end
        end
      rescue ActiveRecord::RecordNotFound
        raise Conflict, "Historical command capture is missing", cause: nil
      rescue ActiveRecord::LockWaitTimeout
        raise Busy, "Historical command is being changed; retry indexing", cause: nil
      rescue ActiveRecord::Encryption::Errors::Decryption, ActiveRecord::SerializationTypeMismatch,
          JSON::ParserError, JSON::GeneratorError, ArgumentError, KeyError, TypeError, EncodingError
        raise Conflict, "Historical command capture cannot be read", cause: nil
      end

      def validate_header!(header, command)
        unless header.origin_kind == "provider" && header.stream == command.stream &&
            header.family_id == command[:family_id] && header.provider_connection_id == command[:provider_connection_id] &&
            header.external_account_id == command[:external_account_id] && header.source_policy_version == command[:source_policy_version] &&
            header.writer_epoch == command[:writer_epoch] && header.scope_key == "account:#{command[:external_account_id]}" &&
            header.provider_sync_type == "ProviderConnection" && uuid?(header.sync_id) &&
            header.schema_version == 1 && header.mode == "snapshot" && header.complete == command[:failed_fx_dates].empty? &&
            %w[import_id account_statement_id provider_authorization_id provider_sync_generation_id generation_role generation_resource].all? { |key| header[key].nil? }
          raise Conflict, "Historical command has a different captured batch owner"
        end
      end

      def validate_payload_bound!(payload)
        # Stored bytes are checked before materialization. Rails decrypts and may
        # decompress/deserialize before this check; historical decompression is
        # not a hard allocation bound. Bound the typed decoder's traversal here.
        stack = [ [ payload, 0 ] ]
        nodes = bytes = 0
        until stack.empty?
          value, depth = stack.pop
          nodes += 1
          raise Conflict, "Historical command exceeds its structural bound" if nodes > MAX_NODES || depth > MAX_DEPTH
          case value
          when Hash
            raise Conflict, "Historical command has invalid encoded keys" unless value.keys.all? { |key| key.is_a?(String) }
            raise Conflict, "Historical command exceeds its structural bound" if nodes + stack.size + value.size * 2 > MAX_NODES
            value.each { |key, item| stack << [ key, depth + 1 ] << [ item, depth + 1 ] }
          when Array
            raise Conflict, "Historical command exceeds its structural bound" if nodes + stack.size + value.size > MAX_NODES
            value.each { |item| stack << [ item, depth + 1 ] }
          when String then bytes += value.bytesize
          when Integer, TrueClass, FalseClass, NilClass then bytes += 8
          when Float
            raise Conflict, "Historical command has a nonfinite encoded value" unless value.finite?
            bytes += 8
          else raise Conflict, "Historical command has an unsupported encoded value"
          end
          raise Conflict, "Historical command exceeds its decoded byte bound" if bytes > MAX_CONTEXT_BYTES
        end
        raise Conflict, "Historical command exceeds its decoded byte bound" if JSON.generate(payload).bytesize > MAX_CONTEXT_BYTES
      end

      def report_failure(error, family_id:, after_id:)
        DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Historical command routing indexing failed",
          source: name, provider_key: "ibkr", family: Family.find_by(id: family_id),
          metadata: { family_id: family_id, after_id: after_id, error_class: error.class.name })
      rescue StandardError
        nil
      end
  end
end
