# Manual requests through a live legacy item follow its exact current writer.
# Provider subclasses declare a trusted manifest key; request data never chooses
# a model, provider or replacement connection.
class Provider::AccountData::LegacySyncRequest
  Fence = Provider::AccountData::LegacyWriterFence
  CONTROL_COLUMNS = %w[id family_id provider_key legacy_type legacy_id state provider_connection_id writer_epoch].freeze

  def self.provider_key
    raise Fence::InvalidSource, "Legacy synchronization requires a declared provider"
  end

  def initialize(item:, actor:)
    @manifest = Provider::AccountData::MigrationManifest.for(self.class.provider_key)
    @item_class = @manifest.item_type.constantize
    unless item.is_a?(@item_class) && item.persisted? && !item.destroyed?
      raise Fence::InvalidSource, "Expected the provider's persisted legacy item"
    end
    @item_id = item.id.dup.freeze
    @family_id = item.family_id.dup.freeze
    @actor_id = actor.id.dup.freeze if actor.is_a?(User) && actor.persisted? && !actor.destroyed?
  end

  def call
    ApplicationRecord.uncached do
      verify_actor!(User.find_by(id: @actor_id))
      expected = routing
      native = expected && ProviderMigrationControl::NATIVE_STATES.include?(expected.fetch("state"))
      item = @item_class.find_by!(id: @item_id, family_id: @family_id)
      admission = native ? :with_exclusive : :with_item
      options = native ? {} : { operation: :sync }
      Fence.public_send(admission, item, **options) do
        ApplicationRecord.transaction(requires_new: true) do
          # Native publication locks its connection first. Other locks remain
          # nonblocking, including the actor used by account/user transfers.
          connection = if expected&.fetch("provider_connection_id")
            ProviderConnection.where(id: expected.fetch("provider_connection_id")).lock("FOR UPDATE NOWAIT").first!
          end
          current = routing(lock: true)
          refuse! unless current == expected
          item = @item_class.where(id: @item_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
          verify_actor!(User.where(id: @actor_id).lock("FOR UPDATE NOWAIT").first)
          refuse! if item.scheduled_for_deletion?

          owner = if native
            verify_native!(current, connection)
            connection
          else
            refuse! if current && !ProviderMigrationControl::LEGACY_STATES.include?(current.fetch("state"))
            item
          end
          # Syncable's request-local UI cache is not scheduling authority.
          unless owner.syncs.visible.exists?
            lock_pending_native_sync!(owner) if native
            owner.sync_later
          end
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    refuse!
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Provider synchronization ownership is busy; retry the request", cause: nil
  end

  private
    def routing(lock: false)
      scope = ProviderMigrationControl.where(legacy_type: @manifest.item_type, legacy_id: @item_id).select(*CONTROL_COLUMNS)
      scope = scope.lock("FOR UPDATE NOWAIT") if lock
      control = scope.first
      refuse! if control && (control.family_id != @family_id || control.provider_key != @manifest.provider_key)
      control&.attributes
    end

    def verify_actor!(actor)
      refuse! unless actor&.active? && actor.admin? && actor.family_id == @family_id
    end

    def lock_pending_native_sync!(owner)
      # Match Syncable's pending-run selection while the connection is locked.
      # Its later blocking lock is then reentrant for the exact selected row.
      candidates = owner.syncs.incomplete.where(cancel_requested_at: nil)
        .where("syncs.created_at > ?", Sync::STALE_AFTER.ago)
      candidates = candidates.where.not(id: candidates.where.not(predecessor_id: nil).select(:predecessor_id))
      candidates.ordered.lock("FOR UPDATE NOWAIT").first
    end

    def verify_native!(control, connection)
      unless connection && connection.id == control.fetch("provider_connection_id") &&
          connection.family_id == @family_id && connection.provider_key == @manifest.provider_key &&
          connection.good? && !connection.scheduled_for_deletion?
        refuse!
      end
      mappings = ProviderMigrationMapping.where(provider_migration_control_id: control.fetch("id"), role: "connection")
        .order(:id).limit(2).lock("FOR UPDATE NOWAIT").to_a
      mapping = mappings.first
      unless mappings.one? && mapping.family_id == @family_id && mapping.legacy_type == @manifest.item_type &&
          mapping.legacy_id == @item_id && mapping.provider_connection_id == connection.id &&
          mapping.external_account_id.nil? && mapping.provider_authorization_id.nil?
        refuse!
      end
    end

    def refuse!
      raise Fence::OwnershipChanged, "Provider synchronization owner is unavailable or changed", cause: nil
    end
end
