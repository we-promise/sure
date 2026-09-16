# Family destruction visits every provider association, including unlinked and
# disabled items. Acquire that entire ownership set before Rails starts deleting
# dependents; a shared connection still requires its own deletion workflow.
class Family::LegacyDestruction
  MAX_ITEMS = 1_000
  RESTRICTED_MODELS = {
    "provider_connections" => "ProviderConnection",
    "provider_migration_controls" => "ProviderMigrationControl",
    "provider_migration_mappings" => "ProviderMigrationMapping",
    "ingestion_batches" => "IngestionBatch"
  }.freeze

  def initialize(family)
    @family = family
    unless family.is_a?(Family) && family.persisted? && family.id.to_s.match?(Fence::UUID)
      raise Fence::InvalidSource, "Expected a persisted family for legacy destruction"
    end
    @family_id = family.id
  end

  def with_admission
    ApplicationRecord.uncached do
      selected = item_headers
      identities = identity_tuples(selected)
      Fence.with_items(selected, operation: :lifecycle) do |admitted|
        raise Fence::OwnershipChanged, "Family provider inventory changed during admission" unless identity_tuples(admitted) == identities

        result = false
        # A savepoint preserves destroy's false/errors contract without letting
        # an enclosing caller commit dependent writes after a callback abort.
        Family.transaction(requires_new: true) do
          lock_owner_rows!(selected)
          family.reload
          current = item_headers
          unless identity_tuples(current) == identities
            raise Fence::OwnershipChanged, "Family provider inventory changed before destruction"
          end
          # Revalidate every current owner under the family row lock. No new
          # advisory lock may be added while this transaction is open.
          Fence.with_items(current, operation: :lifecycle) do
            result = yield unless restricted_dependents?
          end
          raise ActiveRecord::Rollback unless result
        end
        result
      end
    end
  end

  private
    Fence = Provider::AccountData::LegacyWriterFence
    attr_reader :family

    def item_headers
      Provider::AccountData::MigrationManifest.all.sort_by(&:item_type).each_with_object([]) do |manifest, items|
        scope = manifest.item_type.constantize.where(family_id: @family_id).order(:id)
        items.concat(scope.select(:id, :family_id).limit(MAX_ITEMS - items.size + 1).to_a)
        raise Fence::InvalidSource, "Family provider inventory exceeds its admission bound" if items.size > MAX_ITEMS
      end
    end

    def identity_tuples(items)
      items.map { |item| [ item.class.base_class.name, item.id, item.family_id ] }.sort
    end

    def lock_owner_rows!(items)
      Family.where(id: @family_id).lock("FOR UPDATE").first!
      # Transfers take the User first. Materialization can hold an Account FK
      # KEY SHARE lock before taking its owner's User lock. Refuse either busy
      # row before holding item locks or reaching destructive remote callbacks.
      User.where(family_id: @family_id).order(:id).select(:id).lock("FOR UPDATE NOWAIT").load
      Account.where(family_id: @family_id).order(:id).select(:id).lock("FOR UPDATE NOWAIT").load
      items.sort_by { |item| [ item.class.base_class.name, item.id ] }.each do |item|
        # Family's FK lock prevents additions; existing rows also need locks to
        # prevent a removal/reparent between revalidation and remote callbacks.
        item.class.where(id: item.id, family_id: @family_id).select(:id, :family_id).lock("FOR UPDATE NOWAIT").first!
      end
    rescue ActiveRecord::LockWaitTimeout
      raise Fence::Busy, "Family destruction encountered an active user, account, or provider edit", cause: nil
    rescue ActiveRecord::RecordNotFound
      raise Fence::OwnershipChanged, "Family provider inventory disappeared before destruction", cause: nil
    end

    def restricted_dependents?
      restricted = RESTRICTED_MODELS.keys.select do |association|
        RESTRICTED_MODELS.fetch(association).constantize.where(family_id: @family_id).exists?
      end
      restricted.each do |association|
        family.errors.add(:base, :"restrict_dependent_destroy.has_many", record: family.class.human_attribute_name(association).downcase)
      end
      restricted.any?
    end
end
