# Family scheduling and sync history share the same provider inventory. Scheduling
# selects the current owner; history includes both sides throughout migration.
# These queries do not replace the execution fence for already queued jobs.
class Family::ProviderSyncables
  def initialize(family)
    @family = family
  end

  def scheduling_scopes
    legacy = legacy_associations.map do |association|
      controls = ProviderMigrationControl.where(family_id: @family.id, legacy_type: association.klass.base_class.name)
        .where.not(state: ProviderMigrationControl::LEGACY_STATES)
      @family.public_send(association.name).syncable.where.not(id: controls.select(:legacy_id))
    end

    legacy + [ @family.provider_connections.syncable.where(provider_key: Provider::AccountData::Registry.keys) ]
  end

  def history_scopes
    legacy_associations.map { |association| @family.public_send(association.name) } + [ @family.provider_connections ]
  end

  # A retained owner is a history witness, not a schedulable legacy object.
  # Compare the whole projection so absent, extra or mismatched routing fields
  # cannot widen this family query. Archive authentication happens at capture.
  def retained_history_scope
    mappings = ProviderMigrationMapping.joins(:provider_migration_control, :provider_connection)
      .where(family_id: @family.id, role: "connection", provider_authorization_id: nil, external_account_id: nil)
      .where.not(copied_at: nil).where.not(verified_at: nil)
      .where(provider_migration_controls: { family_id: @family.id, state: "retired", writer_epoch: 1,
        copy_version: Provider::AccountData::MigrationManifest::VERSION })
      .where(provider_connections: { family_id: @family.id })
      .where(<<~SQL.squish)
        provider_migration_controls.provider_connection_id = provider_migration_mappings.provider_connection_id
        AND provider_connections.writer_epoch >= 1
        AND provider_migration_controls.provider_key = provider_connections.provider_key
        AND provider_migration_controls.legacy_type = provider_migration_mappings.legacy_type
        AND provider_migration_controls.legacy_id = provider_migration_mappings.legacy_id
        AND provider_migration_controls.audit_results #>> '{native_cutover,format}' = 'provider-native-cutover/v1'
        AND provider_migration_controls.audit_results #>> '{native_cutover,connection_id}' = provider_connections.id::text
        AND provider_migration_controls.audit_results #> '{native_cutover,writer_epoch}' = '1'::jsonb
        AND provider_migration_controls.audit_results #>> '{native_cutover,copy_run_id}' IS NOT NULL
        AND provider_migration_controls.audit_results ->> 'copy_run_id' = provider_migration_controls.audit_results #>> '{native_cutover,copy_run_id}'
        AND provider_migration_mappings.source_checksum ~ '^v1-[0-9a-f]{64}$'
        AND provider_migration_mappings.retained_owner = jsonb_build_object(
          'format', 'retained-provider-owner/v1',
          'family_id', provider_migration_mappings.family_id::text,
          'control_id', provider_migration_controls.id::text,
          'provider_connection_id', provider_connections.id::text,
          'mapping_id', provider_migration_mappings.id::text,
          'role', 'connection',
          'legacy_type', provider_migration_mappings.legacy_type,
          'legacy_id', provider_migration_mappings.legacy_id::text,
          'legacy_item_type', provider_migration_controls.legacy_type,
          'legacy_item_id', provider_migration_controls.legacy_id::text,
          'source_checksum', provider_migration_mappings.source_checksum,
          'copy_run_id', provider_migration_controls.audit_results #>> '{native_cutover,copy_run_id}',
          'copy_version', provider_migration_controls.copy_version
        )
      SQL

    Provider::AccountData::MigrationManifest.all.reduce(mappings.none) do |scope, manifest|
      scope.or(mappings.where(legacy_type: manifest.item_type,
        provider_migration_controls: { provider_key: manifest.provider_key }))
    end
  end

  private
    def legacy_associations
      Family.reflect_on_all_associations(:has_many).select do |association|
        association.name.to_s.end_with?("_items") && association.klass.included_modules.include?(Syncable)
      rescue NameError
        false
      end
    end
end
