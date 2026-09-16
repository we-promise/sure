require "set"

# Account discovery may add consent membership, which is itself a request input.
# Publish that exact addition before constructing the next factory; never mutate
# the grant or evidence that authorized the original response.
class Provider::AccountData::EnableBanking::AuthorizationInventory
  class Conflict < Provider::AccountData::StaleWriter; end
  Result = Data.define(:adapter, :request_grant)
  MAX_RECORDS = 2_000
  MAX_ACCOUNTS = 10_000
  MAX_BYTES = 32 * 1024 * 1024
  GENERATED_COLUMNS = %w[id created_at updated_at lock_version].freeze
  RESERVED_METADATA = %w[linked_account_type balance_snapshot_current runtime_external_account_id runtime_identity_namespace].freeze
  ACCOUNT_COLUMNS = %w[id family_id owner_id accountable_type accountable_id currency status balance cash_balance updated_at].freeze

  def initialize(connection:, sync:, execution: nil)
    @connection, @sync, @execution = connection, sync, execution
  end

  # The caller holds its execution fence and verifies RequestInputs before this
  # call. The second grant check pins all original ownership through publication.
  # The block is the ordinary, database-only ExternalAccount writer.
  def publish!(page:, batch:, adapter:, request_grant:, request_cursor:)
    unless ApplicationRecord.connection.transaction_open? && connection.provider_key == "enable_banking" &&
        adapter.is_a?(Provider::AccountData::EnableBanking) && adapter.request_grant.equal?(request_grant) &&
        request_grant.runtime_inputs? && batch.provider_connection_id == connection.id && batch.family_id == connection.family_id &&
        batch.sync_id == sync.id && batch.stream == "accounts" && batch.scope_key == "connection" &&
        batch.external_account_id.nil? && batch.provider_authorization_id.nil? && !batch.applied?
      raise Conflict, "Consent inventory requires its original account publication"
    end
    capture = page.evidence.fetch(Provider::AccountData::RequestGrant::EVIDENCE_KEY)
    before = request_grant.snapshot
    unless same_factory_snapshot?(before, capture.fetch("after")) && page.records.size <= MAX_RECORDS &&
        Ingestion::Codec.dump(page) == batch.payload && JSON.generate(batch.payload).bytesize <= MAX_BYTES
      raise Conflict, "Consent inventory differs from its original request"
    end
    Provider::AccountData::RequestGrant.with_verified_capture!(connection: connection, capture: capture,
      require_runtime_inputs: true, scope_sync: sync) do
      authorization = admitted_authorization!(page, before, adapter: adapter, request_cursor: request_cursor)
      verify_original_records!(page, authorization, adapter: adapter, observed_at: Time.iso8601(before.dig("runtime_inputs", "observed_at")))
      rows = bounded_accounts
      originals = rows.index_by(&:external_id)
      raise Conflict, "Consent inventory has ambiguous existing identities" unless originals.size == rows.size
      memberships = membership_snapshot
      links = link_snapshot(rows.map(&:id))
      records = page.records.index_by { |record| record[:external_id] }
      raise Conflict, "Consent inventory contains repeated accounts" unless records.size == page.records.size
      records.each_value { |record| validate_record!(record, authorization, originals[record[:external_id]], memberships) }
      next Result.new(adapter: adapter, request_grant: request_grant) if records.empty?
      verify_account_identities!(records, rows)

      expected = records.to_h do |id, record|
        original = originals[id] || connection.external_accounts.build(identity_namespace: "connection", external_id: id,
          family: connection.family, provider_key: connection.provider_key)
        [ id, expected_attributes(original, record) ]
      end
      published = records.values.map { |record| yield record }
      unless published.all? { |external| external.is_a?(ExternalAccount) && external.persisted? } &&
          published.map(&:external_id).sort == records.keys.sort
        raise Conflict, "Consent inventory published a different account set"
      end
      published.each do |external|
        unless external.reload.attributes.except(*GENERATED_COLUMNS) == expected.fetch(external.external_id)
          raise Conflict, "Consent inventory changed an unrelated account field"
        end
        membership = ProviderAuthorizationAccount.find_by(provider_authorization: authorization, external_account: external)
        unless membership
          membership = ProviderAuthorizationAccount.create!(family: connection.family, provider_connection: connection,
            provider_authorization: authorization, external_account: external, status: "active")
          unless membership.reload.active? && membership.family_id == connection.family_id &&
              membership.provider_connection_id == connection.id && membership.provider_authorization_id == authorization.id &&
              membership.external_account_id == external.id && membership.lock_version.zero?
            raise Conflict, "Consent membership changed during publication"
          end
          memberships << membership.attributes
        end
      end
      after_rows = bounded_accounts
      output_ids = published.map(&:id)
      unless after_rows.map(&:id).sort == (rows.map(&:id) | output_ids).sort &&
          after_rows.reject { |row| output_ids.include?(row.id) }.map(&:attributes) == rows.reject { |row| output_ids.include?(row.id) }.map(&:attributes) &&
          membership_snapshot == memberships.sort_by { |row| row.fetch("id") } && link_snapshot(after_rows.map(&:id)) == links
        raise Conflict, "Consent publication changed unrelated ownership"
      end

      next_grant = Provider::AccountData::RequestGrant.new(connection, execution: @execution)
      next_adapter = Provider::AccountData::Registry.build(connection, observed_at: Time.iso8601(before.dig("runtime_inputs", "observed_at")),
        sync: sync, request_grant: next_grant)
      verify_transition!(before, next_grant.snapshot, output_ids, memberships)
      Result.new(adapter: next_adapter, request_grant: next_grant)
    end
  rescue KeyError, TypeError, ArgumentError, NoMethodError, JSON::ParserError, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    raise Conflict, "Consent inventory requires original source reconciliation", cause: nil
  end

  private
    attr_reader :connection, :sync

    # A retry constructs a new factory at the same observed_at. Its wall-clock
    # fingerprint may differ; all actual Enable Banking inputs must still match.
    def same_factory_snapshot?(left, right)
      return false unless left.is_a?(Hash) && right.is_a?(Hash) && left.except("runtime_inputs") == right.except("runtime_inputs")
      first, last = left.fetch("runtime_inputs"), right.fetch("runtime_inputs")
      first.except("frozen_context") == last.except("frozen_context") &&
        first.fetch("frozen_context").except("clock") == last.fetch("frozen_context").except("clock")
    end

    def admitted_authorization!(page, snapshot, adapter:, request_cursor:)
      unless page.evidence.dig(Provider::AccountData::RequestInputs::EVIDENCE_KEY, "cursor") ==
          Provider::AccountData::RuntimeInputs.fingerprint(request_cursor, purpose: "provider-request-inputs/v1")
        raise Conflict, "Consent inventory has a different request cursor"
      end
      state = cursor_state(adapter, request_cursor)
      grants = snapshot.fetch("authorizations")
      index = state.fetch("index")
      unless index < grants.size && page.mode == "snapshot" && page.coverage.empty? && page.removed_ids.empty? &&
          page.progress_cursor.nil? && page.checkpoint_cursor.nil?
        raise Conflict, "Consent inventory has an invalid request position"
      end
      id = page.evidence.fetch("authorization_id")
      original = grants.fetch(index)
      unless original.fetch("id") == id && page.warnings.all? { |warning|
          warning.is_a?(Hash) && warning["authorization_id"] == id &&
            %w[authorization_requires_update authorization_inventory_unavailable].include?(warning["code"])
        }
        raise Conflict, "Consent inventory differs from its requested authorization"
      end
      failed = state.fetch("failed") || page.warnings.any?
      last = index == grants.size - 1
      unless page.complete? == (last && !failed) &&
          (last ? page.next_cursor.nil? : cursor_state(adapter, page.next_cursor) == { "index" => index + 1, "failed" => failed })
        raise Conflict, "Consent inventory cannot change its pagination completeness"
      end
      authorization = connection.provider_authorizations.find_by!(id: id, family_id: connection.family_id)
      unless original && (page.records.empty? || (original["status"] == "active" && original["usable"] && authorization.usable?))
        raise Conflict, "Consent inventory has no usable original authorization"
      end
      authorization
    end

    def cursor_state(adapter, cursor)
      state = adapter.send(:decode_cursor, cursor, "accounts") || { "index" => 0, "failed" => false }
      unless state.keys.sort == %w[failed index] && state["index"].is_a?(Integer) && state["index"] >= 0 &&
          [ true, false ].include?(state["failed"])
        raise Conflict, "Consent inventory cursor is malformed"
      end
      state
    end

    def verify_original_records!(page, authorization, adapter:, observed_at:)
      session = page.evidence["session"]
      if session.nil?
        raise Conflict, "Consent inventory has no captured session" unless page.records.empty? && page.warnings.any?
        return
      end
      raise Conflict, "Consent inventory has a malformed session" unless session.is_a?(Hash)
      session = session.with_indifferent_access
      # An unavailable session has no financial output. Its retained response
      # and warning remain useful without interpreting it as an empty inventory.
      return if page.records.empty? && page.warnings.any?
      sources = session.fetch(:accounts)
      responses = page.evidence.fetch("account_details")
      unless (session[:status].blank? || session[:status] == "AUTHORIZED") &&
          (session.dig(:access, :valid_until).blank? || Time.iso8601(session.dig(:access, :valid_until)) > observed_at) &&
          sources.is_a?(Array) && sources.size <= MAX_RECORDS && responses.is_a?(Array) && responses.size == page.records.size &&
          (page.warnings.any? ? responses.size <= sources.size : responses.size == sources.size)
        raise Conflict, "Consent account outputs have no complete original prefix"
      end
      supplemental = Array(session[:accounts_data]).map(&:with_indifferent_access)
      seen = Set.new
      sources.each_with_index do |raw, index|
        source = raw.is_a?(String) ? { uid: raw }.with_indifferent_access : raw.with_indifferent_access
        uid = adapter.send(:normalized_id, source[:uid])
        raise Conflict, "Consent session repeats an account identity" unless seen.add?(uid)
        next if index >= responses.size

        response = responses.fetch(index).with_indifferent_access
        raise Conflict, "Consent detail response belongs to another account" if response[:uid].present? && response[:uid] != uid
        merged = response.merge(supplemental.find { |row| row[:uid] == uid } || {}).merge(source)
        normalized = adapter.normalize_account(merged, authorization: { id: authorization.id, institution_metadata: authorization.institution_metadata })
        unless normalized.attributes == page.records.fetch(index).attributes
          raise Conflict, "Consent account differs from its original session response"
        end
      end
    end

    def validate_record!(record, authorization, original, memberships)
      metadata = (record[:metadata] || {}).deep_stringify_keys
      details = (record[:sensitive_details] || {}).deep_stringify_keys
      unless record.kind == "account" && metadata["authorization_id"] == authorization.id && metadata["balance_provided"] == false &&
          Provider::AccountData::Syncer::MONETARY_FIELDS.keys.all? { |key| record[key].nil? } && record[:balance_date].nil? &&
          details["api_account_id"].is_a?(String) && details["api_account_id"].present? &&
          details["identification_hashes"].is_a?(Array) && details["identification_hashes"].all? { |id| id.is_a?(String) && id.present? }
        raise Conflict, "Account inventory belongs to another consent"
      end
      return unless original

      owned = memberships.select { |row| row.fetch("external_account_id") == original.id }
      selected = original.metadata["authorization_id"]
      unless original.identity_namespace == "connection" && (selected == authorization.id || (selected.nil? && owned.any?)) &&
          owned.all? { |row| row.fetch("provider_authorization_id") == authorization.id && row.fetch("status") == "active" }
        raise Conflict, "Account discovery cannot replace another consent's ownership"
      end
    end

    def expected_attributes(original, record)
      expected = original.attributes.except(*GENERATED_COLUMNS).deep_dup
      metadata = record[:metadata].deep_stringify_keys.except(*RESERVED_METADATA)
      metadata["reported_currency"] = record[:currency] if record[:currency]
      expected["name"] = record[:name]
      expected["metadata"] = original.metadata.deep_merge(metadata)
      expected["sensitive_details"] = original.sensitive_details.deep_merge(record[:sensitive_details].deep_stringify_keys)
      expected["account_type"] = record[:account_type] if record.attributes.key?(:account_type)
      expected["currency"] = record[:currency] if record[:currency] && (original.currency.blank? || original.currency == record[:currency])
      expected
    end

    def verify_account_identities!(records, originals)
      existing = Hash.new { |hash, key| hash[key] = Set.new }
      originals.each do |external|
        account_identifiers(external.external_id, external.sensitive_details, external.metadata["source_details"]).each do |identity|
          existing[identity] << external.external_id
        end
      end
      incoming = {}
      records.each do |external_id, record|
        account_identifiers(external_id, record[:sensitive_details]).each do |identity|
          if existing.fetch(identity, []).any? { |owner| owner != external_id } ||
              (incoming.key?(identity) && incoming.fetch(identity) != external_id)
            raise Conflict, "Consent inventory aliases refer to different accounts"
          end
          incoming[identity] = external_id
        end
      end
    end

    def account_identifiers(external_id, details, encoded_legacy = nil)
      details = details.with_indifferent_access
      legacy = encoded_legacy ? Provider::AccountData::MigrationValue.decode(encoded_legacy).with_indifferent_access : {}.with_indifferent_access
      identities = [ external_id, details[:api_account_id], *Array(details[:identification_hashes]),
        legacy.dig(:identity, :uid), legacy.dig(:identity, :account_id), *Array(legacy.dig(:identity, :identification_hashes)) ].compact_blank
      raise Conflict, "Consent account identifiers are malformed" unless identities.all? { |identity| identity.is_a?(String) }
      identities.uniq
    end

    def bounded_accounts
      scope = connection.external_accounts.where(family_id: connection.family_id).order(:id)
      headers = scope.limit(MAX_ACCOUNTS + 1).pluck(:id, Arel.sql("xmin::text"), Arel.sql("ctid::text"),
        Arel.sql("COALESCE(octet_length(metadata::text), 0) + COALESCE(octet_length(sensitive_details::text), 0) + " \
          "COALESCE(octet_length(name), 0) + COALESCE(octet_length(external_id), 0) + COALESCE(octet_length(account_type), 0) + " \
          "COALESCE(octet_length(account_subtype), 0) + " \
          "COALESCE(octet_length(identity_namespace), 0) + COALESCE(octet_length(provider_key), 0) + " \
          "COALESCE(octet_length(currency), 0) + COALESCE(octet_length(status), 0)"))
      if headers.size > MAX_ACCOUNTS || headers.sum(&:last) > MAX_BYTES
        raise Provider::AccountData::IncompletePage, "Consent inventory exceeds its account bound"
      end
      return [] if headers.empty?

      tuples = Array.new(headers.size, "(?, ?, ?)").join(", ")
      rows = scope.where("(id::text, xmin::text, ctid::text) IN (VALUES #{tuples})", *headers.flat_map { |row| row.first(3) }).to_a
      raise Conflict, "Consent inventory changed during publication" unless rows.map(&:id) == headers.map(&:first)
      if Provider::AccountData::MigrationValue.dump(rows.map(&:attributes)).bytesize > MAX_BYTES
        raise Provider::AccountData::IncompletePage, "Consent inventory exceeds its decoded account bound"
      end
      rows
    end

    def membership_snapshot
      rows = ProviderAuthorizationAccount.where(provider_connection_id: connection.id).order(:id)
        .limit(Provider::AccountData::RequestGrant::MAX_MEMBERSHIPS + 1).to_a
      if rows.size > Provider::AccountData::RequestGrant::MAX_MEMBERSHIPS || rows.any? { |row| row.family_id != connection.family_id }
        raise Conflict, "Consent membership inventory differs from its owner"
      end
      rows.map(&:attributes)
    end

    def link_snapshot(ids)
      columns = %w[id account_id family_id external_account_id provider_type provider_id provider_key lock_version]
      AccountProvider.where(external_account_id: ids).select(*columns).order(:id).map do |link|
        { "link" => link.attributes,
          "account" => Account.where(id: link.account_id).pick(*ACCOUNT_COLUMNS) }
      end
    end

    def verify_transition!(before, after, outputs, memberships)
      expected_memberships = memberships.map { |row| row.slice("id", "provider_authorization_id", "external_account_id", "lock_version", "status") }
      unless before.except("memberships", "runtime_inputs") == after.except("memberships", "runtime_inputs") &&
          after.fetch("memberships") == expected_memberships.sort_by { |row| row.fetch("id") }
        raise Conflict, "Consent publication changed the captured request grant"
      end
      first, last = before.fetch("runtime_inputs"), after.fetch("runtime_inputs")
      unless first.except("external_accounts", "frozen_context") == last.except("external_accounts", "frozen_context") &&
          first.fetch("frozen_context").except("clock") == last.fetch("frozen_context").except("clock") &&
          first.fetch("external_accounts").except(*outputs) == last.fetch("external_accounts").except(*outputs)
        raise Conflict, "Consent publication changed unrelated normalization inputs"
      end
    end
end
