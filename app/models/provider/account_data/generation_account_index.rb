require "json"
require "time"

# Historical routing, not current publication authority. NULL remains unknown;
# an empty projection is accepted only after checking the original capture.
class Provider::AccountData::GenerationAccountIndex
  MAX_ACCOUNTS = 10_000
  MAX_CONTEXT_BYTES = 32 * 1024 * 1024
  MAX_STORED_BYTES = 48 * 1024 * 1024
  MAX_NODES = 1_000_000
  MAX_DEPTH = 32
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  BINDING_KEYS = %w[external_account_id status resource identity_namespace account_id account_provider_id
    account_currency accountable_type accountable_id account_provider_revision publication source_policy_version authorizations].sort.freeze
  AUTHORIZATION_KEYS = %w[id membership_id membership_status membership_revision authorization_revision status expires_at updated_at].sort.freeze
  Page = Data.define(:processed, :next_cursor, :complete)

  class Conflict < Provider::AccountData::InvalidResponse; end
  class Incomplete < Provider::AccountData::IncompletePage; end
  class Busy < Provider::AccountData::IncompletePage; end

  class << self
    def capture_ids(context_snapshot:, stream:)
      validate_json_bound!(context_snapshot)
      unless %w[transactions activities].include?(stream) && context_snapshot.is_a?(Hash) &&
          context_snapshot["version"] == 1 && context_snapshot["accounts"].is_a?(Hash) &&
          context_snapshot["accounts"].size <= MAX_ACCOUNTS
        raise Conflict, "Generation has no supported original account capture"
      end
      external_ids = []
      ids = context_snapshot.fetch("accounts").map do |external_id, binding|
        unless external_id.is_a?(String) && external_id.present? && external_id.bytesize <= 4_096
          raise Conflict, "Generation account identity is invalid"
        end
        validate_binding!(binding, stream)
        external_ids << binding.fetch("external_account_id")
        binding.fetch("account_id")
      end
      raise Conflict, "Generation account identities are duplicated" unless external_ids.uniq.size == external_ids.size
      ids.compact.uniq.sort.map { |id| id.dup.freeze }.freeze
    rescue JSON::GeneratorError, ArgumentError, TypeError, EncodingError
      raise Conflict, "Generation account capture is malformed", cause: nil
    end

    def verify!(generation:)
      unless generation.is_a?(ProviderSyncGeneration) && generation.persisted? && uuid?(generation.id) && uuid?(generation.family_id)
        raise Conflict, "Expected a persisted provider generation"
      end
      resolve(generation.id, generation.family_id, write: false)
    end

    def for_account(account)
      unless account.is_a?(Account) && uuid?(account.id) && uuid?(account.family_id)
        raise ArgumentError, "Expected a financial account identity"
      end
      ProviderSyncGeneration.where(family_id: account.family_id).where("account_ids @> ARRAY[?]::uuid[]", account.id)
    end

    # Completeness is separate from integrity: verify! checks matching originals.
    def assert_complete_for!(family_id:)
      raise ArgumentError, "Expected a family identity" unless uuid?(family_id)
      if ProviderSyncGeneration.where(family_id: family_id, account_ids: nil).exists?
        raise Incomplete, "Provider generation account captures require reverse indexing"
      end
      true
    end

    def backfill_page(family_id:, after_id: nil, limit: 25)
      unless uuid?(family_id) && (after_id.nil? || uuid?(after_id)) && limit.is_a?(Integer) && (1..100).cover?(limit)
        raise ArgumentError, "Invalid generation account index page"
      end
      unless ProviderSyncGeneration.connection.open_transactions.zero?
        raise Conflict, "Generation index backfill must start outside a transaction"
      end
      ApplicationRecord.uncached do
        scope = ProviderSyncGeneration.where(family_id: family_id, account_ids: nil)
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
      def resolve(id, family_id, write:)
        ApplicationRecord.uncached do
          ProviderSyncGeneration.transaction(requires_new: true) do
            scope = ProviderSyncGeneration.where(id: id, family_id: family_id)
            header = scope.select(:id, :family_id, :stream, :account_ids,
              "octet_length(context_snapshot) AS context_bytes").lock(write ? "FOR UPDATE NOWAIT" : "FOR SHARE NOWAIT").first!
            unless header.context_bytes.is_a?(Integer) && header.context_bytes.positive? && header.context_bytes <= MAX_STORED_BYTES
              raise Conflict, "Generation account capture exceeds its stored byte bound"
            end
            # Repeat the bound on the materializing SELECT. The row lock pins the
            # exact ciphertext until verification and optional projection commit.
            # Rails decrypts/deserializes before the decoded bound is checked;
            # this is not a streaming allocation cap for compressed old captures.
            captured = scope.where("octet_length(context_snapshot) BETWEEN 1 AND ?", MAX_STORED_BYTES)
              .select(:id, :context_snapshot).first!
            ids = capture_ids(context_snapshot: captured.context_snapshot, stream: header.stream)
            if header.account_ids.nil?
              raise Conflict, "Provider generation requires reverse indexing" unless write
              # Update only this column: no re-encryption or timestamp changes.
              header.update_columns(account_ids: ids)
            elsif header.account_ids != ids
              raise Conflict, "Generation account index differs from its original capture"
            end
            ids
          end
        end
      rescue ActiveRecord::RecordNotFound
        raise Conflict, "Generation account capture is missing", cause: nil
      rescue ActiveRecord::LockWaitTimeout
        raise Busy, "Generation account capture is being changed; retry indexing", cause: nil
      rescue ActiveRecord::Encryption::Errors::Decryption, ActiveRecord::SerializationTypeMismatch, JSON::ParserError, ArgumentError, TypeError, EncodingError
        raise Conflict, "Generation account capture cannot be read", cause: nil
      end

      def validate_binding!(binding, stream)
        unless binding.is_a?(Hash) && binding.keys.sort == BINDING_KEYS && uuid?(binding["external_account_id"]) &&
            binding["resource"] == stream && binding["identity_namespace"] == "connection" &&
            %w[active ignored closed identity_unresolved].include?(binding["status"]) &&
            %w[ledger retained].include?(binding["publication"]) && binding["authorizations"].is_a?(Array)
          raise Conflict, "Generation account binding is invalid"
        end
        if binding["account_id"].nil?
          unless %w[account_provider_id account_currency accountable_type accountable_id account_provider_revision source_policy_version].all? { |key| binding[key].nil? } &&
              binding["publication"] == "retained"
            raise Conflict, "Unlinked generation account binding is inconsistent"
          end
        else
          unless %w[account_id account_provider_id accountable_id].all? { |key| uuid?(binding[key]) } &&
              binding["account_currency"].is_a?(String) && binding["account_currency"].present? && binding["account_currency"].bytesize <= 16 &&
              Accountable::TYPES.include?(binding["accountable_type"]) && revision?(binding["account_provider_revision"])
            raise Conflict, "Linked generation account binding is inconsistent"
          end
          if binding["publication"] == "ledger"
            unless binding["status"] == "active" && uuid?(binding["source_policy_version"])
              raise Conflict, "Generation publication binding has no captured selection"
            end
          elsif !binding["source_policy_version"].nil?
            raise Conflict, "Retained generation binding has an unexpected selection"
          end
        end
        authorizations = binding.fetch("authorizations")
        authorizations.each do |authorization|
          unless authorization.is_a?(Hash) && authorization.keys.sort == AUTHORIZATION_KEYS &&
              %w[id membership_id].all? { |key| uuid?(authorization[key]) } &&
              %w[membership_revision authorization_revision].all? { |key| revision?(authorization[key]) } &&
              %w[active revoked].include?(authorization["membership_status"]) &&
              %w[active requires_update revoked].include?(authorization["status"]) &&
              timestamp?(authorization["updated_at"]) && (authorization["expires_at"].nil? || timestamp?(authorization["expires_at"]))
            raise Conflict, "Generation authorization binding is invalid"
          end
        end
        unless %w[id membership_id].all? { |key| authorizations.map { |value| value.fetch(key) }.uniq.size == authorizations.size }
          raise Conflict, "Generation authorization bindings are duplicated"
        end
      end

      def validate_json_bound!(document)
        stack = [ [ document, 0 ] ]
        nodes = bytes = 0
        until stack.empty?
          value, depth = stack.pop
          nodes += 1
          raise Conflict, "Generation account capture exceeds its structural bound" if nodes > MAX_NODES || depth > MAX_DEPTH
          case value
          when Hash
            raise Conflict, "Generation account capture has invalid keys" unless value.keys.all? { |key| key.is_a?(String) }
            raise Conflict, "Generation account capture exceeds its structural bound" if nodes + stack.size + value.size * 2 > MAX_NODES
            value.each { |key, item| stack << [ key, depth + 1 ] << [ item, depth + 1 ] }
          when Array
            raise Conflict, "Generation account capture exceeds its structural bound" if nodes + stack.size + value.size > MAX_NODES
            value.each { |item| stack << [ item, depth + 1 ] }
          when String then bytes += value.bytesize
          when Integer, TrueClass, FalseClass, NilClass then bytes += 8
          else raise Conflict, "Generation account capture has an unsupported value"
          end
          raise Conflict, "Generation account capture exceeds its decoded byte bound" if bytes > MAX_CONTEXT_BYTES
        end
        raise Conflict, "Generation account capture exceeds its decoded byte bound" if JSON.generate(document).bytesize > MAX_CONTEXT_BYTES
      end

      def uuid?(value) = value.is_a?(String) && value.match?(UUID)
      def revision?(value) = value.is_a?(Integer) && value >= 0
      def timestamp?(value)
        value.is_a?(String) && value.bytesize <= 40 && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z\z/) && Time.iso8601(value)
      rescue ArgumentError
        false
      end

      def report_failure(error, family_id:, after_id:)
        DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Provider generation account indexing failed",
          source: name, family: Family.find_by(id: family_id), metadata: { family_id: family_id, after_id: after_id, error_class: error.class.name })
      rescue StandardError
        nil
      end
  end
end
