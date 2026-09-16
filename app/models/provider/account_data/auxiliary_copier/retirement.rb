# A separate native-ownership path. Copy/reverification callers keep their
# pre-cutover admission; this module never creates or changes an archive.
module Provider::AccountData::AuxiliaryCopier::Retirement
  Copier = Provider::AccountData::AuxiliaryCopier
  Conflict = Copier::Conflict
  SourceChanged = Copier::SourceChanged
  MAX_STATE_BYTES = Copier::MAX_STATE_BYTES
  MAX_MANIFEST_BYTES = Copier::MAX_MANIFEST_BYTES
  ATTACHMENT_COLUMNS = Copier::ATTACHMENT_COLUMNS
  BLOB_COLUMNS = Copier::BLOB_COLUMNS
  RETIREMENT_FORMAT = "provider-logo-retirement/v1".freeze
  RETIREMENT_KEYS = %w[format family_id control_id connection_id legacy_type legacy_id archive_format stream
    copy_run_id item_mapping_id checkpoint_id checkpoint_fingerprint archive_fingerprint source_digest content_sha256
    source_attachment_id target_attachment_id blob_id signature].freeze

  # The caller's exclusive permit must span this storage sweep and final apply.
  # This bounded full sweep can read all original ranges (at most MAX_BYTES);
  # unlike verify_retained_page it does not claim an eight-range request budget.
  def prepare_retirement(family:)
    authorize_family!(family)
    @retirement_prepared = @retirement_permit = nil
    item = item_class.find_by!(id: @control.legacy_id, family_id: @control.family_id)
    Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
    permit = ActiveSupport::IsolatedExecutionState[Provider::AccountData::LegacyWriterFence::CONTEXT_KEY]
    receipt = fenced do
      state, expected = retirement_guarded(family: family, retired: false) do |current|
        [ current.deep_dup, retirement_receipt(current) ]
      end
      state.fetch("chunks").times do |index|
        bytes = read_source_chunk(state, index)
        unless bytes == archived_chunk(state, index)
          raise Conflict, "Provider logo storage differs from its retained archive"
        end
      end
      retirement_guarded(family: family, retired: false) do |current|
        unless current == state && retirement_receipt(current) == expected
          raise Conflict, "Provider logo retirement proof changed during storage verification"
        end
        immutable(expected)
      end
    end
    @retirement_permit, @retirement_prepared = permit, receipt
    receipt
  rescue ActiveRecord::RecordNotFound, KeyError, TypeError, Provider::AccountData::StaleWriter
    raise Conflict, "Provider logo retirement proof is missing or changed", cause: nil
  end

  # The surrounding transaction must also retire the item and persist this
  # receipt. A failed outer commit restores the original attachment row.
  def apply_retirement!(family:, receipt:)
    raise ArgumentError, "Logo retirement requires a database transaction" unless ApplicationRecord.connection.transaction_open?
    validate_retirement_receipt!(receipt)
    permit = ActiveSupport::IsolatedExecutionState[Provider::AccountData::LegacyWriterFence::CONTEXT_KEY]
    unless @retirement_prepared == receipt && @retirement_permit && @retirement_permit.equal?(permit)
      raise Conflict, "Logo retirement requires its uninterrupted prepared legacy permit"
    end
    retirement_guarded(family: family, retired: false) do |state|
      raise Conflict, "Provider logo retirement proof changed" unless retirement_receipt(state) == receipt
      attachment_id = receipt.fetch("source_attachment_id")
      if attachment_id
        count = ActiveStorage::Attachment.where(id: attachment_id, name: "logo", record_type: @manifest.item_type,
          record_id: @control.legacy_id, blob_id: receipt.fetch("blob_id")).delete_all
        raise Conflict, "Original provider logo attachment changed" unless count == 1
      end
      immutable(receipt)
    end
  rescue ActiveRecord::RecordNotFound, KeyError, TypeError, Provider::AccountData::StaleWriter
    raise Conflict, "Provider logo retirement proof is missing or changed", cause: nil
  end

  # Read-only replay after the item was removed. Original archive/checkpoint IDs
  # and ciphertext fingerprints, target attachment and blob metadata must agree.
  # Physical storage was checked before retirement; this method performs no HTTP.
  def verify_retirement!(family:, receipt:)
    validate_retirement_receipt!(receipt)
    retirement_guarded(family: family, retired: true) do |state|
      raise Conflict, "Retained provider logo retirement proof changed" unless retirement_receipt(state) == receipt
      immutable(receipt)
    end
  rescue ActiveRecord::RecordNotFound, KeyError, TypeError, Provider::AccountData::StaleWriter
    raise Conflict, "Retained provider logo retirement proof is missing or changed", cause: nil
  end

  private
    def retirement_guarded(family:, retired:)
      authorize_family!(family)
      unless ActiveRecordEncryptionConfig.ready?
        raise Provider::AccountData::MigrationManifest::EncryptionRequired, "Configure encryption before auxiliary verification"
      end
      ApplicationRecord.uncached do
        ApplicationRecord.transaction(requires_new: true) do
          connection_id, control_id, family_id = @control.provider_connection_id, @control.id, @control.family_id
          @connection = ProviderConnection.where(id: connection_id, family_id: family_id).lock("FOR UPDATE NOWAIT").first!
          @control = ProviderMigrationControl.where(id: control_id, family_id: family_id).lock("FOR UPDATE NOWAIT").first!
          validate_retirement_control!(retired: retired)
          if retired
            if item_class.exists?(id: @control.legacy_id) || legacy_logo_attachments.lock("FOR UPDATE NOWAIT").exists?
              raise Conflict, "Retired provider logo still has a legacy owner"
            end
          else
            item = item_class.where(id: @control.legacy_id, family_id: family_id).lock("FOR UPDATE NOWAIT").first!
            Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
          end
          load_retirement_checkpoint!
          state = @checkpoint.state
          manifest = validate_state!(state)
          validate_retirement_copy!(state)
          validate_retirement_attachments!(state, manifest, retired: retired)
          unless verify_archive!(state, lock: true) == state.fetch("content_sha256")
            raise Conflict, "Retained provider logo archive checksum changed"
          end
          yield state
        end
      end
    end

    def validate_retirement_control!(retired:)
      receipt = @control.audit_results["native_cutover"]
      unless @control.state == (retired ? "retired" : "active") && @control.legacy_type == @manifest.item_type &&
          @control.provider_connection_id == @connection.id && @connection.provider_key == @manifest.provider_key &&
          @control.provider_key == @manifest.provider_key && @connection.family_id == @control.family_id &&
          receipt.is_a?(Hash) && receipt["format"] == Provider::AccountData::MigrationCutover::FORMAT &&
          receipt["connection_id"] == @connection.id && receipt["writer_epoch"] == 1 &&
          @control.writer_epoch == 1 && @connection.writer_epoch >= 1 &&
          receipt["copy_run_id"] == @control.high_water_mark["copy_run_id"] &&
          receipt["copy_run_id"] == @control.audit_results["copy_run_id"] &&
          receipt["preparation_run_id"].present? && receipt["preparation_run_id"] == @control.preparation_state["run_id"] &&
          Sync.exists?(id: receipt["sync_id"], syncable_type: "ProviderConnection", syncable_id: @connection.id)
        raise Conflict, "Provider logo retirement requires its original native cutover"
      end
      if !retired && (@connection.lease_owner || @connection.lease_expires_at || @connection.lease_sync_id ||
          @connection.provider_sync_generations.unfinished.exists? || @connection.syncs.incomplete.exists?)
        raise Conflict, "Finish native sync work before provider logo retirement"
      end
    end

    def load_retirement_checkpoint!
      scope = checkpoint_scope.where(scope_key: scope_key)
      bytes = scope.pick(Arel.sql("octet_length(state)"))
      raise Conflict, "Provider logo retirement checkpoint is missing or oversized" unless bytes && bytes <= MAX_STATE_BYTES * 2
      @checkpoint = scope.where("octet_length(state) <= ?", MAX_STATE_BYTES * 2).lock("FOR UPDATE NOWAIT").first!
      unless @connection.provider_sync_checkpoints.where(stream: self.class::STREAM).limit(2).pluck(:id) == [ @checkpoint.id ]
        raise Conflict, "Provider logo retirement checkpoint inventory changed"
      end
      validate_checkpoint!
      unless @checkpoint.state.is_a?(Hash) && Provider::AccountData::MigrationValue.dump(@checkpoint.state).bytesize <= MAX_STATE_BYTES &&
          @checkpoint.state["phase"] == "complete"
        raise Conflict, "Provider logo retirement requires its completed original checkpoint"
      end
    end

    def validate_retirement_copy!(state)
      original = Provider::AccountData::RetainedRow.new(connection: @connection, provider_key: @manifest.provider_key).item
      raise Conflict, "Provider logo retirement has no original item archive" unless original
      copy = state.fetch("retained_copy_context")
      descriptor = original.context
      limit = @control.preparation_state.dig("auxiliary_verification", "context", "limit")
      expected = { "family_id" => @control.family_id, "control_id" => @control.id, "provider_key" => @manifest.provider_key,
        "legacy_id" => @control.legacy_id, "connection_id" => @connection.id,
        "copy_run_id" => descriptor.fetch("copy_run_id"), "manifest_version" => descriptor.fetch("manifest_version"),
        "item_mapping_id" => descriptor.fetch("mapping_id"), "item_checksum" => descriptor.fetch("source_checksum") }
      unless copy.is_a?(Hash) && copy.slice(*expected.keys) == expected && limit.is_a?(Integer) && (1..8).cover?(limit) &&
          @control.preparation_state.dig("auxiliary_verification", "complete") == true &&
          @control.preparation_state.dig("auxiliary_verification", "context") == verification_context(state, limit: limit)
        raise Conflict, "Provider logo retirement differs from the accepted original auxiliary copy"
      end
    end

    def legacy_logo_attachments
      ActiveStorage::Attachment.where(record_type: @manifest.item_type, record_id: @control.legacy_id, name: "logo").order(:id)
    end

    def validate_retirement_attachments!(state, manifest, retired:)
      unless ActiveStorage::Attachment.column_names.sort == ATTACHMENT_COLUMNS.sort && ActiveStorage::Blob.column_names.sort == BLOB_COLUMNS.sort &&
          item_class.reflect_on_all_attachments.map(&:name).map(&:to_s).sort == [ "logo" ] && account_class.reflect_on_all_attachments.empty?
        raise Conflict, "Provider logo retirement requires a reviewed attachment schema"
      end
      source = legacy_logo_attachments.lock("FOR UPDATE NOWAIT").limit(2).to_a
      expected_source = retired ? nil : manifest.fetch("attachment")
      unless source.size <= 1 && source.first&.attributes&.slice(*ATTACHMENT_COLUMNS) == expected_source
        raise SourceChanged, "Provider logo retirement source attachment changed"
      end
      target = target_attachments.lock("FOR UPDATE NOWAIT").limit(2).to_a
      unless target.size <= 1 && target.first&.blob_id == manifest["blob"]&.fetch("id") &&
          target.first&.id == state.fetch("target_attachment_id") &&
          Provider::AccountData::MigrationValue.encode(target.first&.attributes&.slice(*ATTACHMENT_COLUMNS)) == state.fetch("retained_target")
        raise Conflict, "Provider logo retirement target attachment changed"
      end
      return unless manifest["blob"]
      scope = ActiveStorage::Blob.where(id: manifest.fetch("blob").fetch("id"))
      size = "COALESCE(octet_length(metadata::text), 0) + octet_length(key) + octet_length(filename) + octet_length(service_name) + COALESCE(octet_length(content_type), 0)"
      bytes = scope.pick(Arel.sql(size))
      raise Conflict, "Provider logo retirement blob is missing or oversized" unless bytes && bytes <= MAX_MANIFEST_BYTES
      blob = scope.where("#{size} <= ?", MAX_MANIFEST_BYTES).lock("FOR SHARE NOWAIT").first!
      unless blob.attributes.slice(*BLOB_COLUMNS) == manifest.fetch("blob")
        raise Conflict, "Provider logo retirement blob metadata changed"
      end
    end

    def retirement_receipt(state)
      manifest = validate_state!(state)
      checkpoint = checkpoint_scope.where(id: @checkpoint.id).pluck(:id, :scope_key, :schema_version,
        Arel.sql("md5(state)")).sole
      archive = @connection.ingestion_batches.where(stream: self.class::STREAM).order(:sequence, :id)
        .limit(state.fetch("chunks") + 1).pluck(:id, :sequence, :idempotency_key,
          :schema_version, :status, :writer_epoch, Arel.sql("md5(payload)"))
      body = { "format" => RETIREMENT_FORMAT, "family_id" => @control.family_id, "control_id" => @control.id,
        "connection_id" => @connection.id, "legacy_type" => @manifest.item_type, "legacy_id" => @control.legacy_id,
        "archive_format" => self.class::FORMAT, "stream" => self.class::STREAM,
        "copy_run_id" => state.fetch("retained_copy_context").fetch("copy_run_id"),
        "item_mapping_id" => state.fetch("retained_copy_context").fetch("item_mapping_id"),
        "checkpoint_id" => @checkpoint.id, "checkpoint_fingerprint" => fingerprint(checkpoint),
        "archive_fingerprint" => fingerprint(archive), "source_digest" => state.fetch("source_digest"),
        "content_sha256" => state.fetch("content_sha256"), "source_attachment_id" => manifest["attachment"]&.fetch("id"),
        "target_attachment_id" => state.fetch("target_attachment_id"), "blob_id" => manifest["blob"]&.fetch("id") }
      body.merge("signature" => fingerprint([ RETIREMENT_FORMAT, body ]))
    end

    def validate_retirement_receipt!(receipt)
      unless receipt.is_a?(Hash) && receipt.keys.sort == RETIREMENT_KEYS.sort &&
          receipt.all? { |key, value| value.is_a?(String) || (%w[source_attachment_id target_attachment_id blob_id].include?(key) && value.nil?) } &&
          Provider::AccountData::MigrationValue.dump(receipt).bytesize <= MAX_MANIFEST_BYTES &&
          receipt["format"] == RETIREMENT_FORMAT && receipt["archive_format"] == self.class::FORMAT &&
          receipt["stream"] == self.class::STREAM && receipt["signature"].match?(/\A[0-9a-f]{64}\z/) &&
          ActiveSupport::SecurityUtils.secure_compare(receipt["signature"], fingerprint([ RETIREMENT_FORMAT, receipt.except("signature") ]))
        raise Conflict, "Provider logo retirement receipt is invalid"
      end
    end
end
