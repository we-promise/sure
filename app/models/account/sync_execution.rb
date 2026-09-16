require "digest"

# A session lock spans market-data preparation, financial publication and sync
# finalization. A database transaction does not span network calls. The lock is
# released by PostgreSQL if the worker crashes; a duplicate job can then resume.
class Account::SyncExecution
  def self.with(sync)
    unless sync.is_a?(Sync) && sync.persisted? && sync.syncable_type == "Account" && sync.syncable_id.present?
      raise ArgumentError, "Account execution requires a persisted account sync"
    end
    identity = [ sync.id, sync.syncable_type, sync.syncable_id, sync.account_family_id ].freeze
    ApplicationRecord.connection_pool.with_connection do |database|
      raise ArgumentError, "Account execution must start outside a transaction" unless database.open_transactions.zero?
      key = Digest::SHA256.digest([ "sure:account-sync:v1", identity[2] ].join("\0")).unpack1("q>")
      unless database.select_value("SELECT pg_try_advisory_lock(#{key})")
        requeue_if_current(sync, identity)
        return
      end
      failure = nil
      begin
        owner = nil
        # Check the live owner before recovering status or inventing any seal.
        # Account -> Sync matches queue publication; neither row lock spans I/O.
        Sync.transaction(requires_new: true) do
          owner = Account::SyncAdmission.current(account_id: identity[2], family_id: identity[3], lock: true) if identity[3]
          sync.lock!
          unless [ sync.id, sync.syncable_type, sync.syncable_id, sync.account_family_id ] == identity
            raise Provider::AccountData::StaleWriter, "Account execution identity changed before admission"
          end
          if owner
            sync.association(:syncable).target = owner
            # The former worker no longer holds the session lock. A committed
            # financial result retains its original completion marker.
            sync.update!(status: "pending") if sync.syncing?
          else
            sync.stop_unavailable_account!
          end
        end
        return unless owner && sync.in_progress?
        sync.association(:syncable).target = owner
        unless sync.account_inputs_sealed_at
          # Legacy queued rows did not have a seal. Admit them against the
          # account whose session lock was acquired, before dispatch can read a
          # different syncable. The queue rechecks identity under its row lock.
          Account::SyncQueue.new(owner).seal_existing!(sync)
        end
        yield owner
      rescue Account::SyncAdmission::Unavailable
        # Deletion can be scheduled between admission and compatibility sealing.
        # Keep captured inputs intact and never enter the worker in that case.
        sync.with_lock do
          unless [ sync.id, sync.syncable_type, sync.syncable_id, sync.account_family_id ] == identity
            raise Provider::AccountData::StaleWriter, "Account execution identity changed before rejection"
          end
          sync.stop_unavailable_account!
        end
        nil
      rescue ActiveRecord::LockWaitTimeout
        requeue_if_current(sync, identity)
        nil
      rescue StandardError => error
        failure = error
        raise
      ensure
        begin
          raise "Account execution lost its advisory lock" unless database.select_value("SELECT pg_advisory_unlock(#{key})")
        rescue StandardError
          database.disconnect!
          raise unless failure
        end
      end
    end
  end

  def self.requeue_if_current(sync, identity)
    ApplicationRecord.uncached do
      return unless identity[3]
      current = Sync.incomplete.where(id: identity.first, syncable_type: "Account", syncable_id: identity[2], account_family_id: identity[3],
        cancel_requested_at: nil).exists?
      if current && Account::SyncAdmission.current(account_id: identity[2], family_id: identity[3])
        SyncJob.set(wait: 5.seconds).perform_later(sync)
      end
    end
  end
  private_class_method :requeue_if_current
end
