require "base64"
require "openssl"
require "securerandom"
require_relative "migration_manifest"
require_relative "migration_value"

# Builds a disabled, reversible shadow. It never activates a connection or
# invokes legacy processors, destructive callbacks, provider APIs or migrations.
class Provider::AccountData::MigrationCopier
  class Conflict < StandardError; end
  class SnapshotTooLarge < Conflict; end
  class Busy < StandardError; end
  class SourceChanged < StandardError; end

  SNAPSHOT_FORMAT = "legacy-row-v1".freeze
  LEASE_DURATION = 5.minutes
  TARGET_ACCOUNT_COLUMNS = %w[name currency current_balance available_balance cash_balance reserved_balance].freeze
  RETAINED_VERIFICATION_FORMAT = "retained-provider-copy-verification/v1".freeze
  RETAINED_ROW_BYTES = 32 * 1024 * 1024
  RETAINED_ARCHIVE_CHUNKS = 1_024
  COINBASE_PROJECTION_FORMAT = "coinbase-queryable-target/v1".freeze
  COINBASE_PROJECTION_COLUMNS = (TARGET_ACCOUNT_COLUMNS + %w[
    family_id provider_key identity_namespace external_id account_type account_subtype
    balance_date sync_start_date status metadata created_at updated_at
  ]).sort.freeze
  RETAINED_LINK_COLUMNS = %w[id account_id provider_type provider_id external_account_id family_id provider_key lock_version].freeze
  RETAINED_FINANCIAL_CONTEXT_COLUMNS = %w[id family_id currency accountable_type accountable_id].freeze
  ACCOUNT_BINDING_FORMAT = "provider-account-binding/v1".freeze
  VerificationPage = Data.define(:context, :rows, :next_cursor, :complete) do
    def inspect
      "#<#{self.class.name} complete=#{complete} rows=#{rows.size}>"
    end
  end

  attr_reader :manifest, :legacy_item_id, :control

  # The caller verifies the archive checksum and scopes these records first.
  # This comparison is pure so identity planners can share the original binding
  # without querying or reconstructing authority from today's link.
  def self.verify_account_binding!(archive:, link:, financial:)
    captured = account_binding!(archive: archive)
    expected = {
      "format" => ACCOUNT_BINDING_FORMAT,
      "link" => link&.attributes&.slice(*RETAINED_LINK_COLUMNS),
      "financial_context" => financial&.attributes&.slice(*RETAINED_FINANCIAL_CONTEXT_COLUMNS)
    }
    unless captured == expected
      raise Conflict, "Copy-time account binding changed; explicit reconciliation is required"
    end
    true
  end

  def self.account_binding!(archive:)
    binding = archive["account_binding"] if archive.is_a?(Hash)
    unless binding.is_a?(Hash) && binding.keys.all? { |key| key.is_a?(String) } && binding.keys.sort == %w[financial_context format link] &&
        binding["format"] == ACCOUNT_BINDING_FORMAT &&
        ((binding["link"].nil? && binding["financial_context"].nil?) ||
          (binding["link"].is_a?(Hash) && binding["link"].keys.all? { |key| key.is_a?(String) } && binding["link"].keys.sort == RETAINED_LINK_COLUMNS.sort &&
            binding["financial_context"].is_a?(Hash) && binding["financial_context"].keys.all? { |key| key.is_a?(String) } &&
            binding["financial_context"].keys.sort == RETAINED_FINANCIAL_CONTEXT_COLUMNS.sort))
      raise Conflict, "Archive lacks a verified copy-time account binding; explicit historical reconciliation is required"
    end
    binding
  end

  def initialize(provider_key:, legacy_item_id:, batch_size: 100, chunk_bytes: 128 * 1024)
    @manifest = Provider::AccountData::MigrationManifest.for(provider_key)
    @legacy_item_id = legacy_item_id
    @batch_size = Integer(batch_size)
    @chunk_bytes = Integer(chunk_bytes)
    raise ArgumentError, "batch_size must be between 1 and 1000" unless (1..1000).cover?(@batch_size)
    raise ArgumentError, "chunk_bytes must be between 1024 and 1048576" unless (1024..1048576).cover?(@chunk_bytes)
    @owner = SecureRandom.uuid
  end

  # Each call copies or verifies at most batch_size source accounts. Continue
  # calling until shadow. A subsequent call from shadow starts a fresh comparison.
  def run
    run_pass(item_class.find(legacy_item_id), mode: :shadow)
  end

  # Internal preparation primitive, not an activation command. Deploy and drain
  # every legacy writer/lifecycle consumer before relying on this fence. Each
  # bounded pass leaves ownership quiescing, including after errors or crashes.
  # The audit covers only the declared fence and item/account/link copy scope.
  def run_quiesced(restart: false)
    raise ArgumentError, "restart must be a boolean" unless restart == true || restart == false
    LegacyWriterFence.with_exclusive(item_class.find(legacy_item_id)) do |item|
      ProviderCredentialClaim.assert_settled_for!(item)
      QuestradeAccount::ActivitiesRequest.assert_settled_for!(item)
      Provider::AccountData::Questrade::RetainedCredentials.assert_copyable!(item)
      EnableBankingItem::Lifecycle.assert_copyable!(item)
      ApplicationRecord.uncached { run_pass(item, mode: :quiesced, restart: restart) }
    end
  end

  # Abandon pre-activation preparation. This is deliberately not post-cutover
  # rollback: native activity, epochs and leases make it ineligible.
  def resume_legacy!
    LegacyWriterFence.with_exclusive(item_class.find(legacy_item_id)) do |item|
      ApplicationRecord.uncached do
        @control = ProviderMigrationControl.find_by!(legacy_type: manifest.item_type, legacy_id: item.id)
        control.with_lock do
          verify_control_identity!(item)
          raise Conflict, "Only quiesced preparation may resume legacy ownership" unless control.quiescing?
          verify_quiesced_progress!
          reject_live_copy_lease!
          verify_pre_activation!
          control.update!(state: "legacy", lease_owner: nil, lease_expires_at: nil,
            high_water_mark: {}, audit_results: {}, error_code: nil)
        end
        control.reload
      end
    end
  end

  # Read-only comparison against the original quiesced copy, including after
  # financial identity publication. Unlike restart, this preserves the copy run,
  # archives, mappings and every checkpoint. A complete page only ends this
  # enumeration; a cutover coordinator must retain and reconcile all page results.
  def verify_retained_quiesced_page(family:, cursor: nil, limit: 100)
    unless family.is_a?(Family) && family.persisted? && limit.is_a?(Integer) && (1..500).cover?(limit)
      raise ArgumentError, "Retained verification requires an authorized family and bounded page size"
    end
    @control = nil
    item = item_class.find_by!(id: legacy_item_id, family_id: family.id)
    LegacyWriterFence.with_exclusive(item) do
      ProviderCredentialClaim.assert_settled_for!(item)
      QuestradeAccount::ActivitiesRequest.assert_settled_for!(item)
      Provider::AccountData::Questrade::RetainedCredentials.assert_copyable!(item)
      EnableBankingItem::Lifecycle.assert_copyable!(item)
      ApplicationRecord.uncached do
        ApplicationRecord.transaction do
          @control = ProviderMigrationControl.lock.find_by!(legacy_type: manifest.item_type, legacy_id: item.id, family_id: family.id)
          verify_control_identity!(item)
          verify_quiesced_progress!
          reject_live_copy_lease!
          verify_pre_activation!(retained_identity_verification: true)
          unless control.quiescing? && control.copy_version == MigrationManifest::VERSION &&
              control.high_water_mark["phase"] == "verified" && control.audit_results["copy_run_id"] == control.high_water_mark["copy_run_id"] &&
              control.audit_results["copy_mode"] == "quiesced" && control.audit_results["declared_writer_fence_held"] == true
            raise Conflict, "Retained verification requires the original verified quiesced copy"
          end
          item = retained_source_row!(item_class.where(id: item.id, family_id: family.id))
          connection_mapping = verify_retained_item!(item)
          verify_retained_inventory!
          Provider::AccountData::RetainedAccountIndex.assert_complete_for!(control)
          context = retained_verification_context(connection_mapping, limit)
          after_id = retained_verification_cursor(cursor, context)
          scope = account_scope.order(:id)
          scope = scope.where("id > ?", after_id) if after_id
          ids = scope.limit(limit + 1).pluck(:id)
          rows = ids.first(limit).map do |id|
            source = retained_source_row!(account_scope.where(id: id))
            verify_retained_account!(source)
          end
          verify_retained_inventory!
          complete = ids.size <= limit
          next_cursor = context.merge("after_id" => ids.fetch(limit - 1)) unless complete
          VerificationPage.new(context: freeze_verification_value(context), rows: freeze_verification_value(rows),
            next_cursor: freeze_verification_value(next_cursor), complete: complete)
        end
      end
    end
  rescue ActiveRecord::RecordNotFound => error
    capture_retained_verification_failure(error, family)
    raise Conflict, "Retained copy ownership is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Busy, "Retained copy verification encountered an active edit; retry the page", cause: nil
  rescue StandardError => error
    capture_retained_verification_failure(error, family)
    raise
  end

  # Public recovery/read API: reconstruct the exact typed source values from the
  # mapping's encrypted chunks. An explicit checksum can select an older retained
  # copy; callers must authorize the mapping's family, never use today's link.
  def snapshot_for(mapping, source_checksum: nil, max_bytes: nil, max_chunks: nil)
    source_checksum = mapping.source_checksum if source_checksum.nil?
    unless source_checksum.is_a?(String) && source_checksum.match?(/\Av1-[0-9a-f]{64}\z/)
      raise Conflict, "Invalid migration snapshot checksum"
    end
    [ max_bytes, max_chunks ].each do |limit|
      raise ArgumentError, "Snapshot limits must be positive integers" unless limit.nil? || (limit.is_a?(Integer) && limit.positive?)
    end
    batches = IngestionBatch.where(
      family_id: mapping.family_id, origin_kind: "migration",
      provider_connection_id: mapping.provider_migration_control.provider_connection_id,
      stream: "legacy_snapshot", scope_key: snapshot_scope(mapping.legacy_type, mapping.legacy_id)
    ).where("idempotency_key LIKE ?", "#{snapshot_prefix(mapping, source_checksum: source_checksum)}:%").order(:sequence)
    inventory = batches.limit(max_chunks && max_chunks + 1).pluck(:id, Arel.sql("COALESCE(octet_length(payload::text), 0)"))
    raise Conflict, "Missing migration snapshot" if inventory.empty?
    if (max_chunks && inventory.size > max_chunks) ||
        (max_bytes && inventory.sum { |_, size| size.to_i } > max_bytes * 4 + inventory.size * 4_096)
      raise SnapshotTooLarge, "Migration snapshot exceeds its read bound"
    end
    # Read one encrypted chunk at a time. The stored preflight allows bounded
    # encryption/base64 overhead; the decoded budget below is exact source bytes.
    bytes = String.new(encoding: Encoding::BINARY)
    inventory.each_with_index do |(id, _size), index|
      batch = batches.find(id)
      payload = batch.payload
      unless payload["format"] == SNAPSHOT_FORMAT && payload["chunks"] == inventory.size &&
          payload["sequence"] == index && payload["source_type"] == mapping.legacy_type &&
          payload["source_id"] == mapping.legacy_id && batch.sequence == index
        raise Conflict, "Invalid migration snapshot provenance"
      end
      decoded = Base64.strict_decode64(payload.fetch("data"))
      raise SnapshotTooLarge, "Migration snapshot exceeds its read bound" if max_bytes && bytes.bytesize + decoded.bytesize > max_bytes
      bytes << decoded
    end
    bytes.force_encoding(Encoding::UTF_8)
    raise Conflict, "Migration snapshot checksum mismatch" unless checksum(bytes) == source_checksum

    MigrationValue.load(bytes)
  end

  private
    MigrationManifest = Provider::AccountData::MigrationManifest
    MigrationValue = Provider::AccountData::MigrationValue
    LegacyWriterFence = Provider::AccountData::LegacyWriterFence

    def retained_source_row!(scope)
      table = scope.klass.connection.quote_table_name(scope.klass.table_name)
      bytes = scope.pick(Arel.sql("octet_length(to_jsonb(#{table})::text)"))
      raise Conflict, "Retained source row exceeds its verification bound" unless bytes && bytes <= RETAINED_ROW_BYTES
      scope.where("octet_length(to_jsonb(#{table})::text) <= ?", RETAINED_ROW_BYTES).lock("FOR UPDATE NOWAIT").first!
    end

    def verify_retained_projection!(mapping, projection)
      actual = snapshot_for(mapping, max_bytes: RETAINED_ROW_BYTES, max_chunks: RETAINED_ARCHIVE_CHUNKS)
      verify_source_projection!(actual, projection)
      unless mapping.family_id == control.family_id && mapping.verified_at && mapping.copied_at
        raise Conflict, "Retained source mapping has not been verified"
      end
      Provider::AccountData::RetainedAccountIndex.verify!(mapping: mapping) if mapping.role == "external_account"
      actual
    end

    def verify_retained_item!(item)
      projection = manifest.extract_item(item)
      mapping = existing_mapping(projection, "connection")
      unless mapping.provider_connection_id == control.provider_connection_id && control.provider_migration_mappings.where(role: "connection").count == 1
        raise Conflict, "Retained connection mapping changed"
      end
      archive = verify_retained_projection!(mapping, projection)
      connection = control.provider_connection.reload
      verify_attributes!(connection, connection_attributes(projection, auxiliary_inputs: archive["auxiliary_inputs"]))
      unless connection.credentials == connection_credentials(projection)
        raise Conflict, "Retained connection credentials differ"
      end
      verify_checkpoint!(projection, connection: connection)
      if manifest.authorization_required?
        authorization_mapping = existing_mapping(projection, "authorization")
        verify_retained_projection!(authorization_mapping, projection)
        authorization = authorization_mapping.target
        unless authorization&.provider_connection_id == connection.id && authorization.family_id == control.family_id
          raise Conflict, "Retained authorization ownership differs"
        end
        authorization.lock!("FOR UPDATE NOWAIT")
        verify_attributes!(authorization, authorization_attributes(projection))
        raise Conflict, "Retained authorization credentials differ" unless authorization.credentials == authorization_credentials(projection)
      end
      mapping
    end

    def verify_retained_account!(source)
      projection = manifest.extract_account(source)
      mapping = existing_mapping(projection, "external_account")
      archive = verify_retained_projection!(mapping, projection)
      external = mapping.target
      unless external&.provider_connection_id == control.provider_connection_id && external.family_id == control.family_id
        raise Conflict, "Retained external account ownership differs"
      end
      links = AccountProvider.where(provider_type: manifest.account_type, provider_id: source.id).limit(2).to_a
      direct = if %w[plaid simplefin].include?(manifest.provider_key)
        Account.where("#{manifest.provider_key}_account_id" => source.id).limit(2).to_a
      else
        []
      end
      raise Conflict, "Retained financial ownership is ambiguous" if links.size > 1 || direct.size > 1
      link = links.first
      account_id = link&.account_id || direct.first&.id
      original_link = link&.attributes&.slice("id", "account_id", "provider_type", "provider_id", "external_account_id", "family_id", "provider_key", "lock_version")
      financial = Account.where(id: account_id, family_id: control.family_id).lock("FOR UPDATE NOWAIT").first! if account_id
      external.lock!("FOR UPDATE NOWAIT")
      link&.lock!("FOR UPDATE NOWAIT")
      if link && link.attributes.slice(*original_link.keys) != original_link
        raise Conflict, "Retained financial link changed during verification"
      end
      if link && (link.family_id != control.family_id || link.provider_key != manifest.provider_key || link.external_account_id != external.id)
        raise Conflict, "Retained financial link has different provider ownership"
      end
      expected = if coinbase_account_projection?(projection)
        retained_coinbase_attributes!(archive, link: link, financial: financial)
      else
        external_account_attributes(projection, source: source)
      end
      self.class.verify_account_binding!(archive: archive, link: link, financial: financial)
      verify_attributes!(external, expected)
      raise Conflict, "Retained sensitive account details differ" unless external.sensitive_details == account_sensitive_details(projection)
      verify_link!(source, external)
      verify_checkpoint!(projection, connection: control.provider_connection, account: external)
      verify_authorization_membership!(external)
      { "mapping_id" => mapping.id, "legacy_id" => source.id, "external_account_id" => external.id,
        "source_checksum" => mapping.source_checksum, "account_id" => financial&.id,
        "account_currency" => financial&.currency, "accountable_type" => financial&.accountable_type, "accountable_id" => financial&.accountable_id,
        "account_provider_id" => link&.id, "account_provider_revision" => link&.lock_version,
        "disposition" => financial ? "linked" : "unlinked" }
    end

    def verify_retained_inventory!
      mappings = control.provider_migration_mappings.where(role: "external_account")
      exact = mappings.where(family_id: control.family_id, legacy_type: manifest.account_type)
        .where(external_account_id: ExternalAccount.where(provider_connection_id: control.provider_connection_id, family_id: control.family_id).select(:id))
      unless mappings.count == exact.count && mappings.where(verified_at: nil).none? &&
          account_scope.where.not(id: exact.select(:legacy_id)).none? && exact.where.not(legacy_id: account_scope.select(:id)).none? &&
          control.provider_connection.external_accounts.where.not(id: exact.select(:external_account_id)).none?
        raise SourceChanged, "Retained source and target inventories differ"
      end
      authorizations = ProviderAuthorization.where(provider_connection_id: control.provider_connection_id)
      authorization_mappings = control.provider_migration_mappings.where(role: "authorization")
      memberships = ProviderAuthorizationAccount.where(provider_connection_id: control.provider_connection_id)
      if manifest.authorization_required?
        authorization_mapping = authorization_mappings.where(family_id: control.family_id, legacy_type: manifest.item_type, legacy_id: legacy_item_id).sole
        exact_memberships = memberships.where(family_id: control.family_id, provider_authorization_id: authorization_mapping.provider_authorization_id,
          external_account_id: exact.select(:external_account_id), status: "active")
        unless authorization_mappings.count == 1 && authorizations.count == 1 &&
            authorizations.where(id: authorization_mapping.provider_authorization_id, family_id: control.family_id).exists? &&
            memberships.count == exact_memberships.count && exact_memberships.count == exact.count
          raise Conflict, "Retained authorization inventory differs"
        end
      elsif authorizations.exists? || authorization_mappings.exists? || memberships.exists?
        raise Conflict, "Retained copy has an unreviewed authorization inventory"
      end
    end

    def retained_verification_context(item_mapping, limit)
      connection = control.provider_connection
      { "format" => RETAINED_VERIFICATION_FORMAT, "family_id" => control.family_id, "control_id" => control.id,
        "provider_key" => manifest.provider_key, "legacy_id" => legacy_item_id, "connection_id" => connection.id,
        "copy_run_id" => control.high_water_mark.fetch("copy_run_id"), "manifest_version" => control.copy_version,
        "item_mapping_id" => item_mapping.id, "item_checksum" => item_mapping.source_checksum,
        "credential_revision" => connection.credential_revision, "region" => connection.region, "environment" => connection.environment,
        "account_count" => account_scope.count, "page_size" => limit, "requires_cutover_reverification" => true }
    end

    def retained_verification_cursor(cursor, context)
      return if cursor.nil?
      unless cursor.is_a?(Hash) && cursor.except("after_id") == context && cursor["after_id"].is_a?(String) &&
          cursor["after_id"].match?(LegacyWriterFence::UUID) && account_scope.where(id: cursor["after_id"]).exists?
        raise Conflict, "Retained copy continuation has stale or invalid context"
      end
      cursor.fetch("after_id")
    end

    def freeze_verification_value(value)
      case value
      when Hash then value.to_h { |key, item| [ freeze_verification_value(key), freeze_verification_value(item) ] }.freeze
      when Array then value.map { |item| freeze_verification_value(item) }.freeze
      when String then value.dup.freeze
      else value.freeze
      end
    end

    def capture_retained_verification_failure(error, family)
      return if error.is_a?(Busy) || error.is_a?(LegacyWriterFence::Busy) || error.is_a?(ArgumentError)
      DebugLogEntry.capture(category: "provider_migration_error", level: "error", message: "Retained provider copy requires verification review",
        source: self.class.name, provider_key: manifest.provider_key, family_id: family&.id,
        metadata: { migration_control_id: control&.id, legacy_item_id: legacy_item_id,
          operation: "verify_retained_quiesced_copy", error_class: error.class.name })
    rescue StandardError
      nil
    end

    def run_pass(item, mode:, restart: false)
      @mode = mode
      @restart = restart
      @lease_acquired = false
      raise MigrationManifest::EncryptionRequired, "Configure encryption before copying provider data" unless ActiveRecordEncryptionConfig.ready?

      @control = find_control(item)
      acquire_lease!
      unless quiesced? && control.high_water_mark["phase"] == "verified"
        copy_item!
        phase = control.reload.high_water_mark.fetch("phase", "copy")
        phase == "verify" ? verify_accounts! : copy_accounts!
      end
      control.reload
    rescue SourceChanged => error
      reset_after_source_change!
      capture_failure(error) if @lease_acquired
      raise
    rescue StandardError => error
      record_failure!(error)
      raise
    ensure
      release_lease! if @lease_acquired
      @mode = nil
      @restart = false
      @lease_acquired = false
    end

    def quiesced?
      @mode == :quiesced
    end

    def copying_state?
      quiesced? ? control.quiescing? : control.copying?
    end

    def progress(phase, after_id: nil)
      result = control.high_water_mark.slice("mode", "copy_run_id").merge("phase" => phase)
      result["after_id"] = after_id if after_id
      result
    end

    def item_class
      manifest.item_type.constantize
    end

    def account_class
      manifest.account_type.constantize
    end

    def account_scope
      account_class.where(manifest.account_foreign_key => legacy_item_id)
    end

    def find_control(item)
      attributes = { legacy_type: manifest.item_type, legacy_id: item.id }
      ProviderMigrationControl.find_or_create_by!(attributes) do |row|
        row.family_id = item.family_id
        row.provider_key = manifest.provider_key
        row.high_water_mark = {}
        row.copy_version = MigrationManifest::VERSION
      end.tap do |row|
        verify_control_identity!(item, row)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def acquire_lease!
      control.with_lock do
        allowed = ProviderMigrationControl::LEGACY_STATES + (quiesced? ? [ "quiescing" ] : [])
        raise Conflict, "Cannot copy a connection in this ownership state" unless allowed.include?(control.state)
        reject_preparation_progress!
        reject_live_copy_lease!
        if control.copy_version != MigrationManifest::VERSION
          raise Conflict, "Migration manifest version differs"
        end
        verify_pre_activation! if quiesced?
        verify_quiesced_progress! if quiesced? && control.quiescing?
        reset = quiesced? ? !control.quiescing? || @restart : control.legacy? || control.shadow?
        watermark = reset ? { "phase" => "copy" } : control.high_water_mark
        watermark = watermark.merge("mode" => "quiesced", "copy_run_id" => SecureRandom.uuid) if quiesced? && reset
        if quiesced? && reset && manifest.provider_key == "plaid"
          watermark = watermark.merge("plaid_binding_capture_pending" => true)
        end
        control.update!(
          state: quiesced? ? "quiescing" : "copying", error_code: nil, lease_owner: @owner,
          lease_expires_at: LEASE_DURATION.from_now,
          high_water_mark: watermark, audit_results: reset ? {} : control.audit_results
        )
      end
      @lease_acquired = true
    end

    def with_lease
      control.with_lock do
        unless control.lease_owner == @owner && copying_state? && control.lease_expires_at&.future?
          raise Busy, "Migration lease changed or expired"
        end
        raise Conflict, "Shared connection must remain disabled during copy" if control.provider_connection && !control.provider_connection.disabled?
        verify_pre_activation! if quiesced?

        control.update!(lease_expires_at: LEASE_DURATION.from_now)
        yield
      end
    end

    def verify_control_identity!(item, row = control)
      unless row.family_id == item.family_id && row.provider_key == manifest.provider_key
        raise Conflict, "Migration source ownership differs"
      end
    end

    def reject_live_copy_lease!
      if control.lease_owner.present? && control.lease_expires_at&.future?
        raise Busy, "Another copier owns this connection"
      end
    end

    def verify_quiesced_progress!
      unless control.high_water_mark["mode"] == "quiesced" && control.high_water_mark["copy_run_id"].present? &&
          %w[copy verify verified].include?(control.high_water_mark["phase"])
        raise Conflict, "Quiescence belongs to another preparation protocol"
      end
    end

    def verify_pre_activation!(retained_identity_verification: false)
      reject_preparation_progress! unless retained_identity_verification == true
      raise Conflict, "Preparation cannot reverse a native writer epoch" unless control.writer_epoch.zero?
      return unless control.provider_connection_id

      connection = ProviderConnection.lock.find(control.provider_connection_id)
      checkpoint_streams = [ "legacy_state" ]
      if Provider::AccountData::AuxiliaryCopier.supports?(manifest.provider_key)
        auxiliary_stream = Provider::AccountData::AuxiliaryCopier.stream_for(manifest.provider_key)
        if retained_identity_verification == true
          checkpoint_streams << auxiliary_stream
        elsif connection.provider_sync_checkpoints.where(stream: auxiliary_stream).exists? ||
            connection.ingestion_batches.where(stream: auxiliary_stream).exists?
          raise Conflict, "Retained auxiliary evidence requires its original copy; explicit reconciliation is required"
        end
      end
      if retained_identity_verification == true
        checkpoint_streams << "legacy_financial_identities"
        checkpoint_streams << "legacy_binance_history" if manifest.provider_key == "binance"
        checkpoint_streams << "legacy_plaid_cached_changes" if manifest.provider_key == "plaid"
      elsif EntrySource.where(bootstrap_external_account_id: connection.external_accounts.select(:id)).exists? ||
          connection.ingestion_batches.where(origin_kind: "migration", stream: %w[legacy_financial_identities legacy_binance_history legacy_plaid_cached_changes]).exists?
        raise Conflict, "Retained financial identity evidence requires its original quiesced copy"
      end
      unless connection.family_id == control.family_id && connection.provider_key == manifest.provider_key &&
          connection.disabled? && connection.writer_epoch.zero? && connection.lease_owner.nil? &&
          connection.credential_state.blank? && connection.syncs.none? &&
          connection.ingestion_batches.where.not(origin_kind: "migration").none? &&
          connection.provider_sync_checkpoints.where.not(stream: checkpoint_streams).none?
        raise Conflict, "Preparation requires an unused disabled native connection"
      end
    end

    def reject_preparation_progress!
      if ProviderMigrationControl.where(id: control.id).where.not(preparation_state: nil).exists? ||
          control.provider_migration_mappings.where.not(preparation_state: nil).exists?
        raise Conflict, "Retained preparation progress requires its original quiesced copy"
      end
    end

    def copy_item!
      with_lease do
        item = item_class.find(legacy_item_id)
        item.with_lock do
          projection = manifest.extract_item(item)
          mapping = mapping_for(projection, "connection")
          auxiliary = item_auxiliary_inputs(projection, mapping)
          connection = mapping.target || ProviderConnection.new(family_id: control.family_id, provider_key: manifest.provider_key)
          connection.assign_attributes(connection_attributes(projection, auxiliary_inputs: auxiliary))
          MigrationManifest.assign_encrypted!(connection, attribute: :credentials,
            values: connection_credentials(projection))
          connection.save!
          control.update!(provider_connection: connection)
          save_mapping!(mapping, connection, projection, auxiliary_inputs: auxiliary)
          capture_snapshot!(mapping, projection, auxiliary_inputs: auxiliary)
          copy_checkpoint!(projection, connection: connection)
          copy_authorization!(projection, connection) if manifest.authorization_required?
          if auxiliary && manifest.provider_key == "plaid"
            control.update!(high_water_mark: control.high_water_mark.except("plaid_binding_capture_pending"))
          end
        end
      end
    end

    def copy_accounts!
      ids = next_account_ids(control.high_water_mark["after_id"])
      ids.first(@batch_size).each do |id|
        # Redis/cache I/O stays outside row transactions, while the exclusive
        # quiesced legacy fence remains held for this entire bounded pass.
        auxiliary = if quiesced? && manifest.provider_key == "simplefin"
          { Provider::AccountData::Simplefin::RetainedHint::KEY => Provider::AccountData::Simplefin::RetainedHint.capture(legacy_id: id) }
        end
        with_lease do
          source = account_scope.find(id)
          source.with_lock do
            _link, financial = legacy_link(source)
            # Link locks are already held. Refuse contention instead of waiting
            # in the opposite order to an account-first lifecycle operation.
            financial&.lock!("FOR UPDATE NOWAIT")
            projection = manifest.extract_account(source)
            mapping = mapping_for(projection, "external_account")
            account = mapping.target || ExternalAccount.new(provider_connection: control.provider_connection)
            target_attributes = external_account_attributes(projection, source: source)
            account.assign_attributes(target_attributes)
            MigrationManifest.assign_encrypted!(account, attribute: :sensitive_details, values: account_sensitive_details(projection))
            account.save!
            attach_account_link!(source, account)
            binding = copy_account_binding(source)
            derived = if coinbase_account_projection?(projection)
              coinbase_copy_projection(target_attributes, source: source)
            end
            save_mapping!(mapping, account, projection, account_binding: binding, derived_projection: derived, auxiliary_inputs: auxiliary)
            capture_snapshot!(mapping, projection, account_binding: binding, derived_projection: derived, auxiliary_inputs: auxiliary)
            Provider::AccountData::RetainedAccountIndex.capture!(mapping: mapping)
            attach_authorization!(account)
            copy_checkpoint!(projection, connection: control.provider_connection, account: account)
            control.update!(high_water_mark: progress("copy", after_id: id))
          end
        end
      end
      if ids.length <= @batch_size
        with_lease { control.update!(high_water_mark: progress("verify")) }
      end
    end

    def verify_accounts!
      ids = next_account_ids(control.high_water_mark["after_id"])
      ids.first(@batch_size).each do |id|
        with_lease do
          source = account_scope.find(id)
          source.with_lock do
            projection = manifest.extract_account(source)
            mapping = existing_mapping(projection, "external_account")
            archive = verify_projection!(mapping, projection)
            Provider::AccountData::RetainedAccountIndex.verify!(mapping: mapping)
            link, financial = legacy_link(source)
            financial&.lock!("FOR UPDATE NOWAIT")
            self.class.verify_account_binding!(archive: archive, link: link, financial: financial)
            if coinbase_account_projection?(projection) && archive.key?("derived_projection")
              verify_attributes!(mapping.target, retained_coinbase_attributes!(archive, link: link, financial: financial))
            end
            verify_attributes!(mapping.target, external_account_attributes(projection, source: source))
            raise Conflict, "Sensitive account details differ" unless mapping.target.sensitive_details == account_sensitive_details(projection)
            verify_link!(source, mapping.target)
            verify_checkpoint!(projection, connection: control.provider_connection, account: mapping.target)
            verify_authorization_membership!(mapping.target)
            mapping.update!(verified_at: Time.current)
            control.update!(high_water_mark: progress("verify", after_id: id))
          end
        end
      end
      finalize_verification! if ids.length <= @batch_size
    end

    def next_account_ids(after_id)
      scope = account_scope.order(:id)
      scope = scope.where("id > ?", after_id) if after_id.present?
      scope.limit(@batch_size + 1).pluck(:id)
    end

    def finalize_verification!
      with_lease do
        item = item_class.find(legacy_item_id)
        item.with_lock do
          projection = manifest.extract_item(item)
          mapping = existing_mapping(projection, "connection")
          archive = verify_projection!(mapping, projection)
          verify_attributes!(mapping.target, connection_attributes(projection, auxiliary_inputs: archive["auxiliary_inputs"]))
          unless mapping.target.credentials == connection_credentials(projection)
            raise Conflict, "Connection credentials differ"
          end
          verify_checkpoint!(projection, connection: mapping.target)
          verify_authorization!(projection) if manifest.authorization_required?
          mappings = control.provider_migration_mappings.where(role: "external_account")
          source_ids = account_scope.select(:id)
          unless mappings.count == account_scope.count &&
              mappings.where.not(legacy_id: source_ids).none? && mappings.where(verified_at: nil).none?
            raise SourceChanged, "Source inventory changed during copy"
          end
          Provider::AccountData::RetainedAccountIndex.assert_complete_for!(control)
          mapping.update!(verified_at: Time.current)
          control.update!(state: quiesced? ? "quiescing" : "shadow", high_water_mark: progress("verified"), audit_results: {
            "source_account_count" => mappings.count, "snapshot_checksums_verified" => true,
            "source_quiesced" => false, "requires_cutover_reverification" => true,
            "declared_writer_fence_held" => quiesced?, "copy_mode" => quiesced? ? "quiesced" : "shadow",
            "copy_run_id" => control.high_water_mark["copy_run_id"],
            "scope" => "legacy_item_and_account_columns_and_account_links",
            "legacy_associations_retained" => true,
            "verified_at" => Time.current.iso8601, "manifest_version" => MigrationManifest::VERSION
          })
        end
      end
    end

    def item_auxiliary_inputs(projection, mapping)
      return unless quiesced? && manifest.provider_key == "plaid"

      binding = Provider::AccountData::Plaid::DeploymentBinding
      lock_deployment_settings!
      # Item copying repeats on every bounded pass. Retain this copy run's
      # original binding and capture time rather than recapturing today's app.
      if mapping.persisted? && IngestionBatch.exists?(family_id: control.family_id, idempotency_key: "#{snapshot_prefix(mapping)}:0")
        archive = snapshot_for(mapping, max_bytes: RETAINED_ROW_BYTES, max_chunks: RETAINED_ARCHIVE_CHUNKS)
        retained = archive.dig("auxiliary_inputs", binding::KEY)
        if retained && retained["copy_run_id"] == control.high_water_mark.fetch("copy_run_id")
          verify_source_projection!(archive, projection)
          return archive.fetch("auxiliary_inputs")
        end
      end
      # A shadow comparison has no binding. An explicit pre-proof restart has
      # another run ID. Both create a new archive checksum without deleting the
      # former chunks; a same-run retry above must keep its original document.
      unless control.high_water_mark["plaid_binding_capture_pending"] == true
        raise Conflict, "Plaid preparation lacks its original deployment binding; explicitly restart the unused copy"
      end
      { binding::KEY => binding.capture(projection: projection, copy_run_id: control.high_water_mark.fetch("copy_run_id")) }
    end

    def lock_deployment_settings!
      raise Conflict, "Deployment binding requires the copy transaction" if ApplicationRecord.connection.open_transactions.zero?
      Setting.connection.execute("LOCK TABLE #{Setting.connection.quote_table_name(Setting.table_name)} IN SHARE MODE")
    end

    def connection_attributes(projection, auxiliary_inputs: nil)
      values = projection.attributes
      deployment = auxiliary_inputs&.[](Provider::AccountData::Plaid::DeploymentBinding::KEY) if manifest.provider_key == "plaid"
      {
        name: values.fetch("name"), status: "disabled",
        external_id: projection.identity["plaid_id"] || projection.identity["profile_id"] || projection.identity["user_institution_id"],
        region: projection.settings["plaid_region"], environment: deployment ? deployment.fetch("environment") : projection.settings["environment"],
        scheduled_for_deletion: values["scheduled_for_deletion"] == true,
        pending_account_setup: values["pending_account_setup"] == true,
        sync_start_date: values["sync_start_date"]&.to_date,
        settings: connection_settings(projection, deployment: deployment),
        metadata: legacy_metadata(projection),
        created_at: values["created_at"], updated_at: values["updated_at"]
      }
    end

    def connection_settings(projection, deployment: nil)
      settings = projection.settings.except(*manifest.authorization_fields).merge(projection.identity.slice("profile_id"))
      settings = settings.merge(Provider::AccountData::Plaid::DeploymentBinding::KEY => deployment) if deployment
      if %w[trade_republic trading212].include?(manifest.provider_key)
        # This is the source account's denomination, not the family's reporting
        # currency. Keep the original column in its typed archive as well.
        settings = settings.merge(projection.attributes.slice("currency"))
      end
      settings
    end

    def connection_credentials(projection)
      credentials = projection.credentials.except(*manifest.authorization_fields)
      return credentials unless manifest.provider_key == "snaptrade"

      # Token expiry and metadata travel with the token through refreshes. The
      # checkpoint remains historical evidence; it cannot drive the live session.
      expiry = projection.checkpoints["oauth_token_expires_at"]
      credentials.merge(projection.settings.slice("oauth_scope", "oauth_token_type"))
        .merge("oauth_token_expires_at" => expiry&.getutc&.iso8601(9))
    end

    def account_sensitive_details(projection)
      if manifest.provider_key == "onchain_wallet"
        return projection.sensitive_data.merge("source_descriptor" => Provider::AccountData::OnchainWallet::SourceDescriptor.from_projection(projection))
      end
      return projection.sensitive_data unless manifest.provider_key == "coinstats"

      projection.sensitive_data.merge("source_descriptor" => Provider::AccountData::Coinstats::SourceDescriptor.from_projection(projection))
    end

    def external_account_attributes(projection, source:)
      values = projection.attributes
      attributes = TARGET_ACCOUNT_COLUMNS.to_h { |column| [ column.to_sym, values[column] ] }
      attributes[:current_balance] = values["balance"] if values.key?("balance")
      result = attributes.merge(
        family_id: control.family_id, provider_key: manifest.provider_key,
        identity_namespace: projection.identity_namespace, external_id: projection.external_id,
        account_type: values["account_type"] || values["plaid_type"],
        account_subtype: values["account_subtype"] || values["account_sub_type"] || values["plaid_subtype"],
        balance_date: values["balance_date"]&.to_date,
        sync_start_date: values["sync_start_date"]&.to_date,
        status: external_status(projection), metadata: legacy_metadata(projection),
        created_at: values["created_at"], updated_at: values["updated_at"]
      )
      manifest.provider_key == "coinbase" ? coinbase_account_attributes(projection, result, source: source) : result
    end

    # Coinbase's source current_balance/currency describe asset units, while the
    # canonical monetary columns describe the linked account's native value.
    # Preserve the original typed row separately; this is only its queryable view.
    def coinbase_account_attributes(projection, attributes, source:)
      _link, linked = legacy_link(source)
      linked&.lock!
      values = projection.attributes
      payload = projection.payloads["raw_payload"]
      raise MigrationManifest::InvalidSource, "Invalid Coinbase wallet snapshot" unless payload.nil? || payload.is_a?(Hash)
      payload = (payload || {}).with_indifferent_access
      native = payload[:native_balance]
      raise MigrationManifest::InvalidSource, "Invalid Coinbase native valuation" unless native.nil? || native.is_a?(Hash)
      native = (native || {}).with_indifferent_access
      currency_data = payload[:currency].is_a?(Hash) ? payload[:currency].with_indifferent_access : {}
      quantity = values["current_balance"].nil? ? nil : coinbase_decimal(values["current_balance"])
      native_amount = native[:amount].nil? ? nil : coinbase_decimal(native[:amount])
      linked_currency = linked && coinbase_currency(linked.currency)
      native_currency = native[:currency].present? ? coinbase_currency(native[:currency]) : nil
      currency = native_amount.nil? ? linked_currency || native_currency : native_currency || linked_currency || "USD"
      amount = native_amount.nil? ? linked&.balance : native_amount
      origin = if !native_amount.nil?
        "legacy_native_balance"
      elsif linked
        "linked_account_snapshot"
      else
        "unavailable"
      end
      metadata = attributes.fetch(:metadata).merge(
        "asset" => { "code" => values["currency"], "quantity" => quantity&.to_s("F"),
          "name" => currency_data[:name] || values["currency"], "type" => currency_data[:type] },
        "wallet_type" => values["account_type"], "wallet_status" => values["account_status"],
        "valuation" => { "origin" => origin, "native_amount" => native_amount&.to_s("F"),
          "requires_provider_refresh" => true },
        "balance_provided" => !amount.nil?, "balance_policy" => { "cash_balance" => "cash_balance" }
      )
      cash_balance = linked.cash_balance if linked && linked_currency == currency
      attributes.merge(currency: currency, current_balance: amount, cash_balance: cash_balance,
        available_balance: nil, reserved_balance: nil, account_type: "Crypto", metadata: metadata)
    end

    def coinbase_decimal(value)
      unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(BigDecimal)
        raise ArgumentError
      end
      number = BigDecimal(value.to_s)
      raise ArgumentError unless number.finite?
      number
    rescue ArgumentError
      raise MigrationManifest::InvalidSource, "Coinbase quantities and valuations require exact decimals", cause: nil
    end

    def coinbase_currency(value)
      raise ArgumentError unless value.is_a?(String) && value.match?(/\A[A-Za-z]{3}\z/)
      code = value.upcase
      Money::Currency.new(code)
      code
    rescue ArgumentError, Money::Currency::UnknownCurrencyError
      raise MigrationManifest::InvalidSource, "Coinbase native valuation requires a recognized currency", cause: nil
    end

    def external_status(projection)
      return "identity_unresolved" if projection.unresolved_identity?
      return "ignored" if projection.settings["ignored"] == true
      return "closed" if projection.attributes["account_status"].to_s.downcase == "closed"
      "active"
    end

    def legacy_metadata(projection)
      {
        "legacy_type" => projection.source_type, "legacy_id" => projection.source_id,
        "manifest_version" => MigrationManifest::VERSION,
        "ingestion_namespace" => projection.ingestion_namespace,
        "source_details" => MigrationValue.encode(projection.buckets.slice(:identity, :attributes, :settings, :metadata))
      }
    end

    def copy_authorization!(projection, connection)
      mapping = mapping_for(projection, "authorization")
      authorization = mapping.target || ProviderAuthorization.new(provider_connection: connection)
      authorization.assign_attributes(authorization_attributes(projection))
      MigrationManifest.assign_encrypted!(authorization, attribute: :credentials, values: authorization_credentials(projection))
      authorization.save!
      save_mapping!(mapping, authorization, projection)
    end

    def authorization_attributes(projection)
      {
        external_id: projection.credentials["authorization_id"],
        status: projection.attributes["status"] == "requires_update" || projection.credentials["session_id"].blank? ? "requires_update" : "active",
        expires_at: projection.checkpoints["session_expires_at"],
        institution_metadata: projection.metadata.slice("aspsp_name", "institution_id", "institution_name")
          .merge(projection.identity.slice("aspsp_id")),
        metadata: { "legacy_type" => projection.source_type, "legacy_id" => projection.source_id,
          "grant_settings" => projection.settings.slice(*manifest.authorization_fields) }
      }
    end

    def authorization_credentials(projection)
      projection.credentials.slice(*manifest.authorization_fields).merge(projection.sensitive_data.slice(*manifest.authorization_fields))
    end

    def verify_authorization!(projection)
      mapping = existing_mapping(projection, "authorization")
      verify_projection!(mapping, projection)
      verify_attributes!(mapping.target, authorization_attributes(projection))
      unless mapping.target.credentials == authorization_credentials(projection)
        raise Conflict, "Authorization credentials differ"
      end
      mapping.update!(verified_at: Time.current)
    end

    def attach_authorization!(account)
      return unless manifest.authorization_required?
      authorization = control.provider_migration_mappings.find_by!(role: "authorization").target
      ProviderAuthorizationAccount.find_or_create_by!(provider_authorization: authorization, external_account: account) do |membership|
        membership.family_id = control.family_id
        membership.provider_connection_id = control.provider_connection_id
      end
    end

    def verify_authorization_membership!(account)
      return unless manifest.authorization_required?
      authorization = control.provider_migration_mappings.find_by!(role: "authorization").target
      membership = ProviderAuthorizationAccount.find_by(provider_authorization: authorization, external_account: account)
      unless membership&.active? && membership.family_id == control.family_id && membership.provider_connection_id == control.provider_connection_id
        raise Conflict, "Copied authorization membership differs"
      end
    end

    def copy_checkpoint!(projection, connection:, account: nil)
      return if projection.checkpoints.empty?
      checkpoint = ProviderSyncCheckpoint.find_or_initialize_by(
        provider_connection: connection, stream: "legacy_state", scope_key: snapshot_scope(projection.source_type, projection.source_id)
      )
      checkpoint.family_id = control.family_id
      checkpoint.external_account = account
      checkpoint.state = { "format" => SNAPSHOT_FORMAT, "columns" => MigrationValue.encode(projection.checkpoints) }
      checkpoint.schema_version = MigrationManifest::VERSION
      checkpoint.save!
    end

    def verify_checkpoint!(projection, connection:, account: nil)
      return if projection.checkpoints.empty?
      checkpoint = ProviderSyncCheckpoint.find_by(
        provider_connection: connection, stream: "legacy_state", scope_key: snapshot_scope(projection.source_type, projection.source_id)
      )
      unless checkpoint && checkpoint.family_id == control.family_id && checkpoint.external_account_id == account&.id &&
          checkpoint.state == { "format" => SNAPSHOT_FORMAT, "columns" => MigrationValue.encode(projection.checkpoints) } &&
          checkpoint.schema_version == MigrationManifest::VERSION && checkpoint.ingestion_batch_id.nil?
        raise Conflict, "Copied checkpoint state differs"
      end
    end

    def legacy_link(source)
      links = AccountProvider.where(provider_type: manifest.account_type, provider_id: source.id).lock.to_a
      raise Conflict, "Multiple links for one source account" if links.size > 1
      link = links.first
      direct = if %w[plaid simplefin].include?(manifest.provider_key)
        Account.where("#{manifest.provider_key}_account_id" => source.id).lock.to_a
      else
        []
      end
      raise Conflict, "Multiple direct links for one source account" if direct.size > 1
      if link && direct.first && link.account_id != direct.first.id
        raise Conflict, "Legacy direct and join links disagree"
      end
      account = link&.account || direct.first
      raise Conflict, "Cross-family legacy link" if account && account.family_id != control.family_id
      [ link, account ]
    end

    def attach_account_link!(source, external)
      link, account = legacy_link(source)
      return unless account
      link ||= AccountProvider.new(account: account, provider_type: manifest.account_type, provider_id: source.id)
      if link.external_account_id.present? && link.external_account_id != external.id
        raise Conflict, "Existing shared link disagrees with migration mapping"
      end
      link.update!(external_account: external, family_id: control.family_id, provider_key: manifest.provider_key)
    end

    def verify_link!(source, external)
      link, account = legacy_link(source)
      shared = AccountProvider.find_by(external_account_id: external.id)
      if account
        unless shared && shared.id == link&.id && shared.account_id == account.id && shared.family_id == control.family_id
          raise Conflict, "Financial account linkage changed"
        end
      elsif shared
        raise Conflict, "Unlinked source gained a financial account"
      end
    end

    def mapping_for(projection, role)
      control.provider_migration_mappings.find_or_initialize_by(legacy_type: projection.source_type, legacy_id: projection.source_id, role: role)
    end

    def existing_mapping(projection, role)
      control.provider_migration_mappings.find_by!(legacy_type: projection.source_type, legacy_id: projection.source_id, role: role)
    end

    def save_mapping!(mapping, target, projection, account_binding: nil, derived_projection: nil, auxiliary_inputs: nil)
      mapping.public_send("#{ProviderMigrationMapping::TARGETS.fetch(mapping.role)}=", target)
      mapping.family_id = control.family_id
      mapping.source_version = projection.attributes["updated_at"]&.iso8601(9)
      mapping.source_checksum = checksum(serialized_projection(projection, account_binding: account_binding, derived_projection: derived_projection, auxiliary_inputs: auxiliary_inputs))
      mapping.copied_at = Time.current
      mapping.verified_at = nil
      mapping.save!
    end

    def serialized_projection(projection, account_binding: nil, derived_projection: nil, auxiliary_inputs: nil)
      document = {
        "format" => SNAPSHOT_FORMAT, "manifest_version" => MigrationManifest::VERSION,
        "provider_key" => manifest.provider_key, "source_type" => projection.source_type,
        "source_table" => projection.source_table, "source_id" => projection.source_id,
        "dispositions" => manifest.dispositions(projection.kind), "columns" => projection.column_metadata,
        "attributes" => projection.source_attributes
      }
      document["account_binding"] = account_binding if account_binding
      document["derived_projection"] = derived_projection if derived_projection
      document["auxiliary_inputs"] = auxiliary_inputs if auxiliary_inputs
      MigrationValue.dump(document)
    end

    def capture_snapshot!(mapping, projection, account_binding: nil, derived_projection: nil, auxiliary_inputs: nil)
      serialized = serialized_projection(projection, account_binding: account_binding, derived_projection: derived_projection, auxiliary_inputs: auxiliary_inputs)
      if IngestionBatch.exists?(family_id: control.family_id, idempotency_key: "#{snapshot_prefix(mapping)}:0")
        raise Conflict, "Existing captured source differs" unless snapshot_for(mapping) == MigrationValue.load(serialized)
        return
      end
      chunks = (serialized.bytesize + @chunk_bytes - 1) / @chunk_bytes
      chunks.times do |index|
        attributes = {
          family_id: control.family_id, provider_connection_id: control.provider_connection_id,
          external_account_id: mapping.role == "external_account" ? mapping.external_account_id : nil,
          origin_kind: "migration", stream: "legacy_snapshot", scope_key: snapshot_scope(mapping.legacy_type, mapping.legacy_id),
          sequence: index, idempotency_key: "#{snapshot_prefix(mapping)}:#{index}",
          schema_version: MigrationManifest::VERSION, mode: "unknown", complete: false,
          coverage: {}, payload: {
            "format" => SNAPSHOT_FORMAT, "source_type" => projection.source_type,
            "source_id" => projection.source_id, "sequence" => index, "chunks" => chunks,
            "data" => Base64.strict_encode64(serialized.byteslice(index * @chunk_bytes, @chunk_bytes))
          }, ruleset_snapshot: {}
        }
        batch = IngestionBatch.find_or_initialize_by(family_id: control.family_id, idempotency_key: attributes[:idempotency_key])
        if batch.persisted?
          raise Conflict, "Existing captured chunk differs" unless batch.payload == attributes[:payload]
        else
          batch.assign_attributes(attributes)
          batch.save!
        end
      end
    end

    def verify_projection!(mapping, projection)
      archive = snapshot_for(mapping)
      verify_source_projection!(archive, projection)
      archive
    end

    def verify_source_projection!(archive, projection)
      source_document = archive.dup
      auxiliary = source_document.delete("auxiliary_inputs")
      verify_auxiliary_inputs!(auxiliary, projection)
      if source_document.key?("account_binding")
        unless projection.source_type == manifest.account_type
          raise Conflict, "Copied source has an unsupported account binding"
        end
        self.class.account_binding!(archive: source_document)
        source_document.delete("account_binding")
      end
      if source_document.key?("derived_projection")
        unless coinbase_account_projection?(projection) && source_document["derived_projection"].is_a?(Hash) &&
            source_document["derived_projection"]["format"] == COINBASE_PROJECTION_FORMAT
          raise Conflict, "Copied source has an unsupported derived projection"
        end
        source_document.delete("derived_projection")
      end
      unless source_document == MigrationValue.load(serialized_projection(projection))
        raise SourceChanged, "Source row changed after copying"
      end
    end

    def verify_auxiliary_inputs!(auxiliary, projection)
      kind = if manifest.provider_key == "simplefin" && projection.kind == :account
        :simplefin_hint
      elsif manifest.provider_key == "plaid" && projection.kind == :item
        :plaid_deployment
      end
      return unless auxiliary || (kind && control.high_water_mark["mode"] == "quiesced")

      handler = case kind
      when :simplefin_hint then Provider::AccountData::Simplefin::RetainedHint
      when :plaid_deployment then Provider::AccountData::Plaid::DeploymentBinding
      end
      unless handler && auxiliary.is_a?(Hash) && auxiliary.keys == [ handler::KEY ]
        raise Conflict, "Copied source lacks its declared auxiliary input; explicit recopy or reconciliation is required"
      end
      document = auxiliary.fetch(handler::KEY)
      if kind == :simplefin_hint
        handler.validate!(document, legacy_id: projection.source_id)
      else
        lock_deployment_settings!
        handler.validate!(document, legacy_id: projection.source_id, family_id: control.family_id, region: projection.settings["plaid_region"],
          copy_run_id: control.high_water_mark.fetch("copy_run_id"))
        handler.verify_application!(document, application: handler.configured_application(region: projection.settings["plaid_region"]),
          check_legacy_configuration: true)
      end
    end

    def coinbase_account_projection?(projection)
      manifest.provider_key == "coinbase" && projection.source_type == manifest.account_type
    end

    def copy_account_binding(source)
      link, financial = legacy_link(source)
      {
        "format" => ACCOUNT_BINDING_FORMAT,
        "link" => link&.attributes&.slice(*RETAINED_LINK_COLUMNS),
        "financial_context" => financial&.attributes&.slice(*RETAINED_FINANCIAL_CONTEXT_COLUMNS)
      }
    end

    def coinbase_copy_projection(attributes, source:)
      link, financial = legacy_link(source)
      {
        "format" => COINBASE_PROJECTION_FORMAT, "attributes" => attributes.stringify_keys,
        "link" => link&.attributes&.slice(*RETAINED_LINK_COLUMNS),
        "financial_context" => financial&.attributes&.slice(*RETAINED_FINANCIAL_CONTEXT_COLUMNS)
      }
    end

    def retained_coinbase_attributes!(archive, link:, financial:)
      captured = archive["derived_projection"]
      unless captured.is_a?(Hash) && captured.keys.sort == %w[attributes financial_context format link] &&
          captured["format"] == COINBASE_PROJECTION_FORMAT && captured["attributes"].is_a?(Hash) &&
          captured["attributes"].keys.sort == COINBASE_PROJECTION_COLUMNS
        raise Conflict, "Coinbase archive lacks a verified copy-time monetary projection; explicit reconciliation is required"
      end
      unless captured["link"] == link&.attributes&.slice(*RETAINED_LINK_COLUMNS) &&
          captured["financial_context"] == financial&.attributes&.slice(*RETAINED_FINANCIAL_CONTEXT_COLUMNS)
        raise Conflict, "Coinbase copy-time account context changed; explicit reconciliation is required"
      end
      captured.fetch("attributes")
    end

    def verify_attributes!(target, expected)
      expected.each do |name, value|
        raise Conflict, "Copied #{target.class.name} #{name} differs" unless target.read_attribute(name) == value
      end
    end

    def snapshot_scope(type, id)
      "#{type}:#{id}"
    end

    def snapshot_prefix(mapping, source_checksum: mapping.source_checksum)
      "migration:#{mapping.provider_migration_control_id}:#{mapping.legacy_type}:#{mapping.legacy_id}:#{source_checksum}"
    end

    def checksum(serialized)
      key = Rails.application.key_generator.generate_key("provider-migration-checksum-v1", 32)
      "v1-#{OpenSSL::HMAC.hexdigest('SHA256', key, serialized)}"
    end

    def reset_after_source_change!
      return unless @lease_acquired && control&.persisted?
      @control = ProviderMigrationControl.find(control.id)
      control.with_lock do
        if control.lease_owner == @owner && copying_state?
          control.update!(high_water_mark: progress("copy"), audit_results: {}, error_code: "source_changed")
        end
      end
    end

    def record_failure!(error)
      return if !@lease_acquired || error.is_a?(Busy) || error.is_a?(SourceChanged) || !control&.persisted?
      @control = ProviderMigrationControl.find(control.id)
      control.with_lock do
        if control.lease_owner == @owner && copying_state?
          control.update!(state: quiesced? ? "quiescing" : "failed", audit_results: {}, error_code: "copy_failed")
        end
      end
      capture_failure(error)
    rescue StandardError
      # Preserve the original exception; no secrets or raw source values are logged.
      nil
    end

    def capture_failure(error)
      DebugLogEntry.capture(category: "provider_migration_error", level: "warn",
        message: "Provider data copy requires retry or review", source: self.class.name,
        provider_key: manifest.provider_key, family_id: control.family_id,
        metadata: { migration_control_id: control.id, provider_connection_id: control.provider_connection_id,
          copy_mode: quiesced? ? "quiesced" : "shadow", error_class: error.class.name })
    end

    def release_lease!
      return unless control&.persisted?
      @control = ProviderMigrationControl.find(control.id)
      control.with_lock do
        control.update!(lease_owner: nil, lease_expires_at: nil) if control.lease_owner == @owner
      end
    end
end
