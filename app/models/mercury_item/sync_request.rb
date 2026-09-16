# The legacy Mercury route remains usable after its exact connection has migrated.
# Capture the requested owner once; a concurrent handover requires a new request,
# never a fallback that queues work for a different writer.
class MercuryItem::SyncRequest
  Fence = Provider::AccountData::LegacyWriterFence
  CONTROL_COLUMNS = %w[id family_id provider_key legacy_type legacy_id state provider_connection_id writer_epoch].freeze

  def initialize(item:, actor:)
    unless item.is_a?(MercuryItem) && item.persisted?
      raise Fence::InvalidSource, "Expected a persisted Mercury connection"
    end
    @item, @item_id, @family_id, @actor_id = item, item.id, item.family_id, actor&.id
  end

  def call
    ApplicationRecord.uncached do
      expected = routing
      native = expected && ProviderMigrationControl::NATIVE_STATES.include?(expected.fetch("state"))
      admission = native ? :with_exclusive : :with_item
      options = native ? {} : { operation: :sync }
      Fence.public_send(admission, @item, **options) do
        ApplicationRecord.transaction(requires_new: true) do
          # Match native publication's connection-first order. Every additional
          # lock is nonblocking, including the actor lock used by user transfers.
          connection = if expected&.fetch("provider_connection_id")
            ProviderConnection.where(id: expected.fetch("provider_connection_id")).lock("FOR UPDATE NOWAIT").first!
          end
          current = routing(lock: true)
          refuse! unless current == expected
          item = MercuryItem.where(id: @item_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
          actor = User.where(id: @actor_id).lock("FOR UPDATE NOWAIT").first
          refuse! unless actor&.active? && actor.admin? && actor.family_id == @family_id && !item.scheduled_for_deletion?

          owner = if native
            verify_native!(current, connection)
            connection
          else
            refuse! if current && !ProviderMigrationControl::LEGACY_STATES.include?(current.fetch("state"))
            item
          end
          # Read the live relation, not Syncable's request-local UI cache.
          owner.sync_later unless owner.syncs.visible.exists?
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    refuse!
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Mercury synchronization ownership is busy; retry the request", cause: nil
  end

  private
    def routing(lock: false)
      scope = ProviderMigrationControl.where(legacy_type: "MercuryItem", legacy_id: @item_id).select(*CONTROL_COLUMNS)
      scope = scope.lock("FOR UPDATE NOWAIT") if lock
      control = scope.first
      if control && (control.family_id != @family_id || control.provider_key != "mercury")
        refuse!
      end
      control&.attributes
    end

    def verify_native!(control, connection)
      unless connection && connection.id == control.fetch("provider_connection_id") &&
          connection.family_id == @family_id && connection.provider_key == "mercury" &&
          connection.good? && !connection.scheduled_for_deletion?
        refuse!
      end
      mappings = ProviderMigrationMapping.where(provider_migration_control_id: control.fetch("id"), role: "connection")
        .order(:id).limit(2).lock("FOR UPDATE NOWAIT").to_a
      mapping = mappings.first
      unless mappings.one? && mapping.family_id == @family_id && mapping.legacy_type == "MercuryItem" &&
          mapping.legacy_id == @item_id && mapping.provider_connection_id == connection.id &&
          mapping.external_account_id.nil? && mapping.provider_authorization_id.nil?
        refuse!
      end
    end

    def refuse!
      raise Fence::OwnershipChanged, "Mercury synchronization owner is unavailable or changed", cause: nil
    end
end
