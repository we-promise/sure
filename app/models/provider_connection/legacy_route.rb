# A saved legacy URL selects its original shared connection. It cannot create a
# replacement connection, revive a missing source or reinterpret an old form.
class ProviderConnection::LegacyRoute
  Result = Data.define(:connection, :sync)

  def initialize(provider_key:, legacy_id:, family:, actor:)
    @manifest = Provider::AccountData::MigrationManifest.for(provider_key)
    @legacy_id = legacy_id
    @family, @actor = family, actor
  end

  def call(sync: false, include_live: false)
    raise ArgumentError, "Live synchronization uses its provider's owner request" if sync && include_live
    return unless @legacy_id.is_a?(String) && @legacy_id.match?(Provider::AccountData::LegacyWriterFence::UUID)
    ApplicationRecord.uncached do
      # Live compatibility rows normally keep their existing admission. Providers
      # may opt their management screens into this route once shared setup and
      # configuration exist; old submissions only receive a fresh destination.
      source_exists = @manifest.item_type.constantize.exists?(id: @legacy_id)
      return if source_exists && !include_live
      control = ProviderMigrationControl.find_by(family_id: @family.id, provider_key: @manifest.provider_key,
        legacy_type: @manifest.item_type, legacy_id: @legacy_id)
      return unless control
      return if source_exists && control.legacy_owned?

      connection = ProviderConnection.find_by!(id: control.provider_connection_id, family_id: @family.id)
      ProviderConnection::Management.new(connection: connection, actor: @actor).with_lock do |context|
        unless context.control&.id == control.id && context.control.native_owned? &&
            context.control.legacy_type == @manifest.item_type && context.control.legacy_id == @legacy_id && context.mapping
          raise ProviderConnection::Management::Conflict, "Legacy connection has no original native owner"
        end
        if source_exists
          source = @manifest.item_type.constantize.where(id: @legacy_id, family_id: @family.id)
            .select(:id, :family_id, :scheduled_for_deletion).lock("FOR UPDATE NOWAIT").first!
          unless context.control.active? && !source.scheduled_for_deletion?
            raise ProviderConnection::Management::Conflict, "Legacy source is unavailable or unexpectedly present after retirement"
          end
        else
          unless context.control.retired?
            raise ProviderConnection::Management::Conflict, "Missing legacy source has no accepted retirement"
          end
          resolved = Provider::AccountData::RetiredOwner.resolve!(mapping: context.mapping, family_id: @family.id)
          Provider::AccountData::RetiredOwner.lock_proof!(resolved.owner.fetch("retired_owner"))
          checked = Provider::AccountData::RetiredOwner.resolve!(mapping: context.mapping, family_id: @family.id)
          unless checked == resolved
            raise ProviderConnection::Management::Conflict, "Retired source ownership changed during routing"
          end
        end
        if sync && !context.connection.good?
          raise ProviderConnection::Management::Conflict, "Restore the native connection before syncing"
        end
        # Syncable retains native pending runs and dispatches after the transaction
        # commits. No work is ever enqueued with the deleted legacy owner.
        run = context.connection.sync_later if sync
        Result.new(connection: context.connection, sync: run)
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise ProviderConnection::Management::Conflict, "Retired connection is unavailable", cause: nil
  end
end
