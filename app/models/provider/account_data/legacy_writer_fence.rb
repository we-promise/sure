require "digest"

# Permit for common dispatch and declared legacy item entrypoints. Direct jobs,
# processors and lifecycle consumers must also join before any live cutover.
class Provider::AccountData::LegacyWriterFence
  class Busy < Provider::AccountData::IncompletePage; end
  class OwnershipChanged < Provider::AccountData::StaleWriter; end
  class InvalidSource < ArgumentError; end

  CONTEXT_KEY = :provider_legacy_writer_fence
  NAMESPACE = "sure:legacy-provider-writer:v1".freeze
  OPERATIONS = %i[sync ingest publish lifecycle credentials].freeze
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  class << self
    def legacy_item?(record)
      record.is_a?(ApplicationRecord) && item_manifests.key?(record.class.base_class.name)
    end

    def legacy_account?(record)
      record.is_a?(ApplicationRecord) && account_manifests.key?(record.class.base_class.name)
    end

    def with_item(item, operation: :ingest, &block)
      raise ArgumentError, "Unknown legacy operation" unless OPERATIONS.include?(operation)
      new(item).with_shared(operation: operation, &block)
    end

    # A lifecycle caller declares its complete source set before opening a
    # transaction. Callers must recheck their account/family inventory under its
    # row lock; this shared permit excludes migration drains, not other writers.
    def with_items(items, operation: :lifecycle)
      raise ArgumentError, "Multiple legacy items require a lifecycle operation" unless operation == :lifecycle
      raise InvalidSource, "Expected an explicit legacy item array" unless items.is_a?(Array)

      fences = items.map { |item| new(item) }
      if fences.map { |fence| fence.identity.last }.uniq.size > 1
        raise InvalidSource, "Legacy lifecycle items must belong to one family"
      end
      fences = fences.uniq(&:identity).sort_by(&:identity)

      with_locks(fences, :shared) do
        current = fences.map { |fence| fence.send(:admit_shared_source, operation: operation) }.freeze
        yield current
      end
    end

    # The caller may create/reload its control only after this lock succeeds.
    # This method never changes ownership, creates a control or enables a writer.
    def with_exclusive(item, &block)
      new(item).with_exclusive(&block)
    end

    # Evidence producers verify the real session permit; a serialized flag from
    # a plan or request is never proof that legacy publication was drained.
    def assert_exclusive!(item)
      new(item).assert_exclusive!
    end

    def with_account(account, operation: :publish)
      unless account.is_a?(ApplicationRecord) && account.persisted? && account.id.to_s.match?(UUID)
        raise InvalidSource, "Expected a persisted legacy provider account"
      end
      manifest = account_manifests[account.class.base_class.name]
      raise InvalidSource, "Unregistered legacy provider account" unless manifest
      account_class = manifest.account_type.constantize
      item_id = account_class.where(id: account.id).pick(manifest.account_foreign_key)
      item = manifest.item_type.constantize.find_by(id: item_id)
      raise OwnershipChanged, "Legacy provider account no longer has its item" unless item

      with_item(item, operation: operation) do
        current = account_class.uncached { account_class.find_by(id: account.id) }
        unless current && current.read_attribute(manifest.account_foreign_key) == item.id
          raise OwnershipChanged, "Legacy provider account changed its item"
        end
        yield current
      end
    end

    # A selected subset is input data, not authority to publish another item's
    # rows. This helper runs inside a declared item method, before any processing.
    def scoped_accounts!(item, selection)
      assert_admitted_shared_source!(item, "Account subsets require an admitted legacy item")

      with_item(item, operation: :publish) do |current|
        manifest = item_manifests.fetch(current.class.base_class.name)
        account_class = manifest.account_type.constantize
        relation = selection if selection.is_a?(ActiveRecord::Relation)
        unless selection.is_a?(Array) || (relation && relation.klass == account_class)
          raise InvalidSource, "Expected a legacy account array or matching relation"
        end

        account_class.uncached do
          # Loaded relations preserve their selected IDs; unloaded relations
          # evaluate once after admission. Never widen a requested subset.
          selected = selection.to_a
          ids = selected.map do |record|
            unless record.is_a?(account_class) && record.id.to_s.match?(UUID) && !record.new_record? &&
                record.has_attribute?(manifest.account_foreign_key)
              raise InvalidSource, "Expected persisted legacy provider accounts"
            end
            if record.destroyed? || record.read_attribute(manifest.account_foreign_key) != current.id
              raise OwnershipChanged, "Selected account no longer belongs to this item"
            end
            record.id
          end
          next [] if ids.empty?

          if relation
            # The IDs already reflect limit/offset and order. Recheck the scope's
            # predicates without applying its window a second time, so changed
            # manual/visibility filters reject instead of changing the subset.
            eligible = relation.except(:select, :order, :limit, :offset)
              .where(account_class.primary_key => ids).distinct.pluck(account_class.arel_table[account_class.primary_key])
            unless (ids.uniq - eligible).empty?
              raise OwnershipChanged, "Selected account no longer matches its scope"
            end
          end

          fresh = account_class.where(manifest.account_foreign_key => current.id, account_class.primary_key => ids)
            .includes(:account_provider, :account).index_by(&:id)
          unless fresh.size == ids.uniq.size
            raise OwnershipChanged, "Selected account was removed or changed its item"
          end
          if fresh.values.any? { |record| record.current_account && record.current_account.family_id != current.family_id }
            raise OwnershipChanged, "Selected account has a financial link in another family"
          end
          ids.map { |id| fresh.fetch(id) }
        end
      end
    end

    # Delayed legacy work must retain its original Sync owner. Some integrations
    # finish the parent before polling ends; they must opt in to completed runs.
    def scoped_sync!(item, sync, allow_completed: false)
      assert_admitted_shared_source!(item, "Sync context requires an admitted legacy item")
      return unless sync
      unless sync.is_a?(Sync) && sync.persisted?
        raise InvalidSource, "Expected a persisted legacy Sync"
      end

      Sync.uncached do
        current = item.syncs.find_by(id: sync.id)
        unless current && usable_sync?(current, allow_completed: allow_completed)
          raise OwnershipChanged, "Legacy operation lost its sync context"
        end
        seen = [ current.id ]
        ancestor_id = current.parent_id
        while ancestor_id
          ancestor = Sync.find_by(id: ancestor_id)
          unless ancestor && usable_sync?(ancestor, allow_completed: allow_completed) &&
              seen.size < 64 && !seen.include?(ancestor.id)
            raise OwnershipChanged, "Legacy operation lost its sync ancestor"
          end
          seen << ancestor.id
          ancestor_id = ancestor.parent_id
        end
        current
      end
    end

    private
      def assert_admitted_shared_source!(item, message)
        fence = new(item)
        held = ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]
        member = held && held.fetch(:members)[fence.identity]
        unless held && held[:mode] == :shared && held[:database].equal?(ApplicationRecord.connection) &&
            member && member[:source].equal?(item)
          raise InvalidSource, message
        end
      end

      def with_locks(fences, mode)
        ApplicationRecord.connection_pool.with_connection do |database|
          held = ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]
          if held
            unless held[:mode] == mode && held[:database].equal?(database) &&
                fences.all? { |fence| held.fetch(:members).key?(fence.identity) }
              raise ArgumentError, "Legacy operations cannot upgrade or extend an acquired fence"
            end
            # Reentry needs no new lock. Only requested members are rechecked:
            # a lifecycle may already have destroyed another admitted member.
            return yield
          end
          unless fences.empty? || database.open_transactions.zero?
            raise ArgumentError, "Acquire the legacy writer fence before a database transaction"
          end

          suffix = mode == :shared ? "_shared" : ""
          acquired = []
          acquiring = false
          installed = false
          failure = nil
          begin
            fences.each do |fence|
              acquiring = true
              locked = database.select_value("SELECT pg_try_advisory_lock#{suffix}(#{fence.lock_key})")
              acquired << fence.lock_key if locked
              acquiring = false
              raise Busy, "Another operation is draining this legacy provider" unless locked
            end
            # An empty set is still an admission boundary: a later callback
            # cannot silently add a source that was absent from its inventory.
            members = fences.to_h { |fence| [ fence.identity, { source: nil } ] }.freeze
            ActiveSupport::IsolatedExecutionState[CONTEXT_KEY] = { members: members, mode: mode, database: database }
            installed = true
            yield
          rescue Exception => error # rubocop:disable Lint/RescueException -- preserve errors and interrupts during lock cleanup
            failure = error
            raise
          ensure
            ActiveSupport::IsolatedExecutionState.delete(CONTEXT_KEY) if installed
            begin
              # A failed response can hide a successful session acquisition.
              # Its outcome cannot be reconstructed from the local key list.
              raise OwnershipChanged, "Legacy lock acquisition has an uncertain outcome" if acquiring
              acquired.reverse_each do |key|
                released = database.select_value("SELECT pg_advisory_unlock#{suffix}(#{key})")
                raise OwnershipChanged, "Legacy writer session lost its advisory lock" unless released
              end
            rescue StandardError => release_error
              # Disconnect releases any remaining session locks. Never replace
              # the operation's original error with a cleanup failure.
              begin
                database.disconnect!
              rescue StandardError
                # The adapter is already unusable; preserve the useful error.
              end
              raise release_error unless failure
            end
          end
        end
      end

      def usable_sync?(sync, allow_completed:)
        sync.cancel_requested_at.nil? && (sync.in_progress? || (allow_completed && sync.completed?))
      end

      def item_manifests
        Provider::AccountData::MigrationManifest.all.index_by(&:item_type)
      end

      def account_manifests
        Provider::AccountData::MigrationManifest.all.index_by(&:account_type)
      end
  end

  attr_reader :identity, :lock_key

  def initialize(item)
    unless self.class.legacy_item?(item) && item.persisted? && item.id.to_s.match?(UUID) && item.family_id.to_s.match?(UUID)
      raise InvalidSource, "Expected a persisted legacy provider item"
    end
    @item_class = item.class.base_class
    @item_id, @family_id = item.id.to_s.dup.freeze, item.family_id.to_s.dup.freeze
    @provider_key = Provider::AccountData::MigrationManifest.all.find { |manifest| manifest.item_type == @item_class.name }.provider_key
    @identity = [ @item_class.name, @item_id, @family_id ].freeze
    # Signed network-order 64-bit integer, stable across Ruby processes/releases.
    @lock_key = Digest::SHA256.digest([ NAMESPACE, @item_class.name, @item_id ].join("\0")).unpack1("q>")
  end

  def with_shared(operation:)
    self.class.send(:with_locks, [ self ], :shared) do
      yield admit_shared_source(operation: operation)
    end
  end

  def with_exclusive
    self.class.send(:with_locks, [ self ], :exclusive) { yield current_source.first }
  end

  def assert_exclusive!
    held = ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]
    unless held && held.fetch(:members).key?(@identity) && held[:mode] == :exclusive &&
        held[:database].equal?(ApplicationRecord.connection)
      raise InvalidSource, "Migration evidence requires the actual exclusive legacy permit"
    end
    current_source.first
  end

  private
    def admit_shared_source(operation:)
      item, control = current_source
      raise OwnershipChanged, "Legacy provider no longer owns this operation" if control && !control.legacy_owned?
      if operation == :sync && item.respond_to?(:scheduled_for_deletion?) && item.scheduled_for_deletion?
        raise OwnershipChanged, "Legacy provider is scheduled for deletion"
      end
      # Retain observations only on this member's freshly admitted receiver.
      # Never copy transient state from a potentially stale caller.
      held = ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]
      held.fetch(:members).fetch(@identity)[:source] ||= item
    end

    def current_source
      ApplicationRecord.uncached do
        item = @item_class.find_by(id: @item_id, family_id: @family_id)
        raise OwnershipChanged, "Legacy provider source no longer has the expected owner" unless item
        control = ProviderMigrationControl.find_by(legacy_type: @item_class.name, legacy_id: @item_id)
        if control && (control.family_id != @family_id || control.provider_key != @provider_key)
          raise OwnershipChanged, "Legacy migration ownership is inconsistent"
        end
        [ item, control ]
      end
    end
end
