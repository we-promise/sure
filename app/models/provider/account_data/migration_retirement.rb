require "digest"

# Removes only reviewed compatibility rows. Shared financial/source identities,
# their archives and all original Syncs remain available to native consumers.
class Provider::AccountData::MigrationRetirement
  class Conflict < Provider::AccountData::StaleWriter; end
  class Busy < Provider::AccountData::IncompletePage; end

  FORMAT = "provider-native-retirement/v1".freeze
  # Each entry declares the reviewed attachment, direct-FK and deferred-work
  # dispositions. A manifest alone is not permission to delete its source rows.
  DISPOSITIONS = {
    "akahu" => { attachment: "logo", direct_account_foreign_keys: [], deferred_requests: [] }.freeze,
    "up" => { attachment: "logo", direct_account_foreign_keys: [], deferred_requests: [] }.freeze,
    "mercury" => { attachment: "logo", direct_account_foreign_keys: [], deferred_requests: [] }.freeze,
    "brex" => { attachment: "logo", direct_account_foreign_keys: [], deferred_requests: [] }.freeze
  }.freeze
  MAX_ACCOUNTS = 100
  MAX_BYTES = 32 * 1024 * 1024
  MAX_RECEIPT_BYTES = 1024 * 1024
  Result = Data.define(:control_id, :connection_id, :replayed)

  def initialize(provider_key:, legacy_item_id:, family:)
    unless family.is_a?(Family) && family.persisted?
      raise ArgumentError, "Retirement requires an authorized family"
    end
    @provider_key, @legacy_item_id, @family_id = provider_key, legacy_item_id, family.id
  end

  def call
    unless ApplicationRecord.connection.open_transactions.zero?
      raise ArgumentError, "Retirement must acquire its legacy permit before a database transaction"
    end
    raise Conflict, "Provider has no reviewed retirement disposition" unless DISPOSITIONS.key?(@provider_key)
    Provider::AccountData::Registry.fetch(@provider_key)
    raise Conflict, "Configure encryption before retiring compatibility data" unless ActiveRecordEncryptionConfig.ready?
    @family = Family.find(@family_id)
    @manifest = Provider::AccountData::MigrationManifest.for(@provider_key)
    @control = ProviderMigrationControl.find_by!(family_id: @family_id, provider_key: @provider_key,
      legacy_type: manifest.item_type, legacy_id: @legacy_item_id)
    ApplicationRecord.uncached do
      if control.retired?
        ApplicationRecord.transaction(requires_new: true) { replay! }
      else
        item = manifest.item_type.constantize.find_by!(id: @legacy_item_id, family_id: @family_id)
        Fence.with_exclusive(item) do
          # Storage reads finish before row locks; the signed auxiliary receipt
          # pins exactly those bytes/headers for the final database-only step.
          auxiliary = Auxiliary.for(control: control)
          auxiliary_receipt = auxiliary.prepare_retirement(family: family)
          ApplicationRecord.transaction(requires_new: true) { retire!(item, auxiliary, auxiliary_receipt) }
        end
      end
    end
  rescue ActiveRecord::LockWaitTimeout, Provider::AccountData::IncompletePage
    capture_failure(Busy)
    raise Busy, "Migration ownership is busy; finish outstanding work before retirement", cause: nil
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, Ingestion::SourceOwners::InvalidGraph,
      Ingestion::IdentitySigningKeys::InvalidSignature, Ingestion::IdentitySigningKeys::InvalidConfiguration,
      Provider::AccountData::StaleWriter, Auxiliary::Conflict, KeyError
    capture_failure(Conflict)
    raise Conflict, "Retirement evidence or source ownership is missing or changed", cause: nil
  end

  private
    Fence = Provider::AccountData::LegacyWriterFence
    Auxiliary = Provider::AccountData::AuxiliaryCopier
    Value = Provider::AccountData::MigrationValue
    attr_reader :family, :control, :connection, :manifest, :mappings, :sources, :externals, :links

    def retire!(item, auxiliary, auxiliary_receipt)
      lock_control!
      raise Conflict, "Retirement requires an active native cutover" unless control.active?
      raise Conflict, "Restore the native connection before retiring compatibility data" unless connection.good?
      assert_idle!
      load_mappings!
      lock_financial_owners!
      item.lock!("FOR UPDATE NOWAIT")
      Fence.assert_exclusive!(item)
      @sources = bounded(source_scope.select(:id).order(:id).limit(MAX_ACCOUNTS + 1).lock("FOR UPDATE NOWAIT").to_a)
      unless sources.map(&:id).sort == account_mappings.map(&:legacy_id).sort
        raise Conflict, "Retirement requires the complete original source inventory"
      end
      lock_shared_links!
      assert_legacy_idle!(item)
      ProviderCredentialClaim.assert_settled_for!(item)
      assert_attachments!(item)
      assert_stored_source_bound!(item)
      @sources = source_scope.where(id: sources.map(&:id)).order(:id).to_a
      verify_live_archives!(item)
      capture_witnesses!
      # This removes only the admitted original attachment; it never purges a
      # blob or invokes a remote provider's disconnect/destroy callbacks.
      auxiliary.apply_retirement!(family: family, receipt: auxiliary_receipt)
      unless source_scope.delete_all == sources.size &&
          manifest.item_type.constantize.where(id: item.id, family_id: family.id).delete_all == 1
        raise Conflict, "Compatibility source inventory changed during retirement"
      end
      receipt = {
        "format" => FORMAT, "family_id" => family.id, "provider_key" => @provider_key,
        "control_id" => control.id, "connection_id" => connection.id,
        "legacy_type" => manifest.item_type, "legacy_id" => @legacy_item_id,
        "cutover" => control.audit_results.fetch("native_cutover"),
        "mappings" => mapping_receipts, "auxiliary" => auxiliary_receipt,
        "retired_at" => Time.current.utc.iso8601(6)
      }
      receipt["signature"] = signing_keys.sign(receipt_message(receipt))
      control.update!(state: "retired", audit_results: control.audit_results.merge("native_retirement" => receipt))
      # Exercise the same absent-source resolver used by subsequent native
      # consumers before committing the destructive portion of this operation.
      verify_retired_owners!
      result(replayed: false)
    end

    def replay!
      lock_control!
      raise Conflict, "Retirement ownership changed" unless control.retired?
      receipt = control.audit_results["native_retirement"]
      unless receipt.is_a?(Hash) && receipt.keys.sort == %w[auxiliary connection_id control_id cutover family_id format legacy_id legacy_type mappings provider_key retired_at signature]
        raise Conflict, "Retirement has no complete original receipt"
      end
      signing_keys.verify!(receipt.fetch("signature"), receipt_message(receipt.except("signature")))
      expected = { "format" => FORMAT, "family_id" => family.id, "provider_key" => @provider_key,
        "control_id" => control.id, "connection_id" => connection.id,
        "legacy_type" => manifest.item_type, "legacy_id" => @legacy_item_id,
        "cutover" => control.audit_results.fetch("native_cutover") }
      unless receipt.slice(*expected.keys) == expected && !manifest.item_type.constantize.exists?(id: @legacy_item_id) && !source_scope.exists?
        raise Conflict, "Retirement no longer describes absent original sources"
      end
      load_mappings!
      lock_financial_owners!
      lock_shared_links!
      unless mapping_receipts == receipt["mappings"] && !manifest.account_type.constantize.where(id: account_mappings.map(&:legacy_id)).exists?
        raise Conflict, "Retirement source mapping inventory changed"
      end
      verify_retired_owners!
      Auxiliary.for(control: control).verify_retirement!(family: family, receipt: receipt.fetch("auxiliary"))
      result(replayed: true)
    end

    def lock_control!
      @connection = ProviderConnection.where(id: control.provider_connection_id, family_id: family.id).lock("FOR UPDATE NOWAIT").first!
      @control = ProviderMigrationControl.where(id: control.id, family_id: family.id).lock("FOR UPDATE NOWAIT").first!
      unless control.provider_connection_id == connection.id && control.provider_key == @provider_key &&
          connection.provider_key == @provider_key && control.legacy_type == manifest.item_type && control.legacy_id == @legacy_item_id
        raise Conflict, "Retirement connection ownership changed"
      end
    end

    def assert_idle!
      if connection.scheduled_for_deletion? || connection.lease_owner || connection.lease_expires_at || connection.lease_sync_id ||
          control.lease_owner || control.lease_expires_at || connection.syncs.incomplete.exists? ||
          connection.provider_sync_generations.unfinished.exists?
        raise Busy, "Finish outstanding connection work before retirement"
      end
    end

    def load_mappings!
      @mappings = bounded(control.provider_migration_mappings.order(:id).limit(MAX_ACCOUNTS + 2).lock("FOR UPDATE NOWAIT").to_a, maximum: MAX_ACCOUNTS + 1)
      originals = mappings.select { |mapping| mapping.role == "connection" }
      unless originals.one? && originals.first.legacy_type == manifest.item_type && originals.first.legacy_id == @legacy_item_id &&
          originals.first.provider_connection_id == connection.id && originals.first.external_account_id.nil? &&
          mappings.all? { |mapping| mapping.family_id == family.id && mapping.provider_authorization_id.nil? &&
            (mapping.role == "connection" || (mapping.role == "external_account" && mapping.legacy_type == manifest.account_type &&
              mapping.provider_connection_id.nil? && mapping.external_account_id.present?)) }
        raise Conflict, "Retirement requires exact original source mappings"
      end
      @externals = ExternalAccount.where(id: account_mappings.map(&:external_account_id)).order(:id).to_a
      unless externals.size == account_mappings.size && externals.all? { |external| external.family_id == family.id &&
          external.provider_connection_id == connection.id && external.provider_key == @provider_key }
        raise Conflict, "Retirement source mappings changed native ownership"
      end
    end

    def link_scope
      AccountProvider.where(provider_type: manifest.account_type, provider_id: account_mappings.map(&:legacy_id))
        .or(AccountProvider.where(external_account_id: externals.map(&:id)))
    end

    def lock_financial_owners!
      @link_headers = bounded(link_scope.order(:id).limit(MAX_ACCOUNTS + 1).pluck(*Ingestion::SourceOwners::LINK_COLUMNS))
      account_ids = @link_headers.map { |row| row[Ingestion::SourceOwners::LINK_COLUMNS.index("account_id")] }.uniq.sort
      accounts = Account.where(id: account_ids).order(:id).lock("FOR UPDATE NOWAIT").to_a
      unless accounts.size == account_ids.size && accounts.all? { |account| account.family_id == family.id && (control.retired? || !account.pending_deletion?) }
        raise Conflict, "Retirement financial ownership is missing or changed"
      end
      if !control.retired? && Sync.where(syncable_type: "Account", syncable_id: account_ids).incomplete.exists?
        raise Busy, "Finish outstanding account work before retirement"
      end
    end

    def lock_shared_links!
      ExternalAccount.where(id: externals.map(&:id)).order(:id).lock("FOR UPDATE NOWAIT").to_a
      @links = bounded(link_scope.order(:id).limit(MAX_ACCOUNTS + 1).lock("FOR UPDATE NOWAIT").to_a)
      unless links.map { |link| link.attributes.values_at(*Ingestion::SourceOwners::LINK_COLUMNS) } == @link_headers
        raise Conflict, "Retirement financial links changed during admission"
      end
      by_source = account_mappings.index_by(&:legacy_id)
      unless links.all? { |link| link.family_id == family.id && link.provider_key == @provider_key &&
          externals.any? { |external| external.id == link.external_account_id } &&
          ((link.provider_type.nil? && link.provider_id.nil?) ||
            (link.provider_type == manifest.account_type && by_source[link.provider_id]&.external_account_id == link.external_account_id)) }
        raise Conflict, "Retirement cannot detach an ambiguous shared source"
      end
      Ingestion::SourceOwners.capture(family_id: family.id,
        links: links.map { |link| link.attributes.slice(*Ingestion::SourceOwners::LINK_COLUMNS) },
        direct_sources: [], external_ids: externals.map(&:id), connection_ids: [ connection.id ])
    end

    def assert_legacy_idle!(item)
      if item.scheduled_for_deletion? || item.syncs.incomplete.exists? || Sync.where(syncable_type: manifest.account_type, syncable_id: sources.map(&:id)).incomplete.exists?
        raise Busy, "Finish outstanding legacy work before retirement"
      end
    end

    def assert_attachments!(item)
      if ActiveStorage::Attachment.where(record_type: manifest.account_type, record_id: sources.map(&:id)).exists? ||
          ActiveStorage::Attachment.where(record_type: manifest.item_type, record_id: item.id).where.not(name: "logo").exists?
        raise Conflict, "Compatibility sources contain an undeclared attachment"
      end
    end

    def verify_live_archives!(item)
      remaining = MAX_BYTES
      external_by_id = externals.index_by(&:id)
      external_by_source = account_mappings.to_h { |mapping| [ mapping.legacy_id, external_by_id.fetch(mapping.external_account_id) ] }
      original_rows = [ [ item, nil ] ] + sources.map { |source| [ source, external_by_source.fetch(source.id) ] }
      original_rows.each do |source, external|
        raise Conflict, "Retirement archives exceed their read bound" unless remaining.positive?
        retained = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: @provider_key, max_bytes: remaining)
        archive = external ? retained.account(external) : retained.item
        projection = external ? manifest.extract_account(source) : manifest.extract_item(source)
        unless archive.attributes == projection.source_attributes
          raise Conflict, "Compatibility data changed after its original archive; reconcile it before retirement"
        end
        remaining -= archive.byte_size
      end
    end

    def assert_stored_source_bound!(item)
      # Ciphertexts/headers are counted without decrypting cached payloads.
      # Historical Rails compressed documents still allocate on decode; the
      # typed archive and current-value comparison subsequently enforce bounds.
      sql = ApplicationRecord.connection
      item_table = sql.quote_table_name(manifest.item_table)
      account_table = sql.quote_table_name(manifest.account_table)
      item_bytes = manifest.item_type.constantize.where(id: item.id).pick(Arel.sql("octet_length(to_jsonb(#{item_table})::text)"))
      account_bytes = source_scope.sum(Arel.sql("octet_length(to_jsonb(#{account_table})::text)"))
      unless item_bytes && item_bytes + account_bytes <= MAX_BYTES * 4 + (sources.size + 1) * 4096
        raise Conflict, "Compatibility source data exceeds its stored read bound"
      end
    end

    def capture_witnesses!
      remaining = MAX_BYTES
      mappings.each do |mapping|
        remaining -= Provider::AccountData::RetiredOwner.new(mapping: mapping, family_id: family.id, max_bytes: remaining).capture!
      end
      mappings.each(&:reload)
    end

    def verify_retired_owners!
      remaining = MAX_BYTES
      mappings.each do |mapping|
        resolved = Provider::AccountData::RetiredOwner.resolve!(mapping: mapping, family_id: family.id, max_bytes: remaining)
        Provider::AccountData::RetiredOwner.lock_proof!(resolved.owner.fetch("retired_owner"))
        remaining -= resolved.bytes
      end
      true
    end

    def mapping_receipts
      mappings.map { |mapping| mapping.attributes.slice("id", "role", "legacy_type", "legacy_id", "provider_connection_id", "external_account_id", "retained_owner") }
    end

    def receipt_message(receipt)
      bytes = Value.dump(receipt)
      raise Conflict, "Retirement receipt exceeds its bound" if bytes.bytesize > MAX_RECEIPT_BYTES
      "#{FORMAT}\0#{bytes}"
    end

    def signing_keys = Ingestion::IdentitySigningKeys.configured
    def account_mappings = mappings.select { |mapping| mapping.role == "external_account" }
    def source_scope = manifest.account_type.constantize.where(manifest.account_foreign_key => @legacy_item_id)
    def result(replayed:) = Result.new(control_id: control.id, connection_id: connection.id, replayed: replayed).freeze

    def bounded(rows, maximum: MAX_ACCOUNTS)
      raise Conflict, "Retirement inventory exceeds its row bound" if rows.size > maximum
      rows
    end

    def capture_failure(error_class)
      DebugLogEntry.capture(category: "provider_migration_error", level: "error", source: self.class.name,
        provider_key: @provider_key, family_id: @family_id, message: "Provider compatibility retirement requires review",
        metadata: { migration_control_id: control&.id, legacy_item_id: @legacy_item_id, error_class: error_class.name })
    rescue StandardError
      nil
    end
end
