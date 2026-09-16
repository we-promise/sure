class Account::SyncQueue
  def initialize(account)
    @account = account
    @account_id = account.id&.dup&.freeze
    @family_id = account.family_id&.dup&.freeze
  end

  # handoff is supplied only by an exact provider capture. nil copies the
  # account's explicitly selected source, including for an ad hoc recalculation.
  def enqueue(parent_sync: nil, window_start_date: nil, window_end_date: nil, handoff: nil, retry_of: nil)
    raise ArgumentError, "Cannot combine a handoff and retry" if handoff && retry_of
    with_input_locks(parent_sync: parent_sync, handoff: handoff, retry_of: retry_of) do |inputs|
      input_digest = Account::SyncInput.digest(inputs)
      request = { "inputs" => input_digest, "parent_id" => parent_sync&.id,
        "start" => window_start_date, "end" => window_end_date }
      # A provider replays the same handoff into the same child. Ad hoc requests
      # can reuse an identical pending calculation, never a running one.
      request_key = Ingestion::HistoricalBalances.fingerprint(request) if handoff
      existing = if request_key
        @account.syncs.find_by(account_request_key: request_key)
      elsif !retry_of
        @account.syncs.pending.where(parent_id: parent_sync&.id, cancel_requested_at: nil,
          account_inputs_digest: input_digest, window_start_date: window_start_date, window_end_date: window_end_date).ordered.first
      end
      if existing
        SyncJob.perform_later(existing) if existing.pending? && (!existing.predecessor || existing.predecessor.terminal?)
        return existing
      end

      unfinished = @account.syncs.incomplete
      tail = unfinished.where.not(id: unfinished.where.not(predecessor_id: nil).select(:predecessor_id)).ordered.lock.first
      sync = @account.syncs.create!(parent: parent_sync, predecessor: tail, window_start_date: window_start_date,
        window_end_date: window_end_date, account_request_key: request_key)
      inputs.each do |input|
        copy = sync.account_sync_inputs.create!(account: @account, family: @account.family, provider_sync: input.provider_sync,
          source_batch: input.source_batch, kind: input.kind, resource: input.resource, payload: input.payload,
          payload_digest: Ingestion::HistoricalBalances.fingerprint(input.payload))
        if handoff
          selection = Account::SyncSource.find_or_initialize_by(account: @account, resource: copy.resource)
          selection.update!(family: @account.family, account_sync_input: copy)
        end
      end
      sync.update!(account_inputs_sealed_at: Time.current, account_inputs_digest: input_digest)
      SyncJob.perform_later(sync) unless tail
      sync
    end
  end

  # Compatibility for account jobs created before the migration. Seal once,
  # before work; this cannot append inputs to any already-sealed calculation.
  def seal_existing!(sync)
    @account = current_account!
    current_sync = Sync.find(sync.id)
    parent_id = current_sync.parent_id
    verify_sealing_owner!(current_sync, parent_id: parent_id)
    if current_sync.account_inputs_sealed_at
      # A sealed execution owns its original inputs. Admission must not read or
      # replace them with the account's later selected source.
      Sync.transaction(requires_new: true) do
        Sync.where(id: parent_id).lock("FOR KEY SHARE").load if parent_id
        @account = current_account!(lock: true)
        sync.with_lock do
          verify_sealing_owner!(sync, parent_id: parent_id)
          sync.verify_account_inputs!
        end
      end
      return
    end
    with_input_locks(parent_sync: current_sync.parent, handoff: nil, retry_of: nil) do |inputs|
      sync.with_lock do
        verify_sealing_owner!(sync, parent_id: parent_id)
        if sync.account_inputs_sealed_at
          sync.verify_account_inputs!
          return
        end
        unless sync.in_progress?
          raise Provider::AccountData::InvalidResponse, "Cannot seal an unrelated account execution"
        end
        inputs.each do |input|
          sync.account_sync_inputs.create!(account: @account, family: @account.family, provider_sync: input.provider_sync,
            source_batch: input.source_batch, kind: input.kind, resource: input.resource, payload: input.payload, payload_digest: input.payload_digest)
        end
        sync.update!(account_inputs_sealed_at: Time.current, account_inputs_digest: Account::SyncInput.digest(inputs))
      end
    end
  end

  private
    class SelectionChanged < StandardError; end

    def current_account!(lock: false)
      Account::SyncAdmission.fetch!(account_id: @account_id, family_id: @family_id, lock: lock)
    end

    def verify_sealing_owner!(sync, parent_id:)
      unless sync.syncable_type == "Account" && sync.syncable_id == @account_id &&
          sync.account_family_id == @family_id && sync.parent_id == parent_id
        raise Provider::AccountData::InvalidResponse, "Cannot seal an unrelated account execution"
      end
    end

    # New input rows reference the original provider Sync. Acquire its key-share
    # lock before Account, matching the provider's parent-lock -> account handoff
    # order. Otherwise an ad hoc enqueue could deadlock with that parent handoff.
    def with_input_locks(parent_sync:, handoff:, retry_of:)
      attempts = 0
      begin
        @account = current_account!
        planned = requested_inputs(handoff: handoff, retry_of: retry_of)
        # Roll back each attempt to its savepoint before acquiring a changed
        # parent lock set, even when the caller already owns a transaction.
        Sync.transaction(requires_new: true) do
          ids = (planned.map(&:provider_sync_id) + [ parent_sync&.id ]).compact.uniq.sort
          Sync.where(id: ids).order(:id).lock("FOR KEY SHARE").load
          @account = current_account!(lock: true)
          inputs = requested_inputs(handoff: handoff, retry_of: retry_of)
          raise SelectionChanged unless Account::SyncInput.digest(inputs) == Account::SyncInput.digest(planned)
          # Capture can finish before an unlink commits. Recheck the original
          # link/policy under Account before publishing its selected pointer;
          # a live provider lease alone cannot reconnect a disconnected account.
          handoff&.assert_selection!(account: @account, provider_sync: inputs.sole.provider_sync, lock: true)
          yield inputs
        end
      rescue SelectionChanged
        attempts += 1
        retry if attempts < 3
        raise Provider::AccountData::StaleWriter, "Selected account source changed while queueing"
      end
    end

    def requested_inputs(handoff:, retry_of:)
      ApplicationRecord.uncached { read_requested_inputs(handoff: handoff, retry_of: retry_of) }
    end

    def read_requested_inputs(handoff:, retry_of:)
      if handoff
        unless handoff.is_a?(Provider::AccountData::Ibkr::EquityHandoff)
          raise ArgumentError, "Expected a typed provider handoff"
        end
        unless handoff.payload.fetch("account_id") == @account.id && handoff.payload.fetch("family_id") == @account.family_id
          raise Provider::AccountData::InvalidResponse, "Account handoff belongs to another family or account"
        end
        provider_sync = Sync.find(handoff.payload.fetch("provider_sync_id"))
        source_batch = IngestionBatch.where(sync: provider_sync, family: @account.family).find(handoff.payload.fetch("source_batch_id"))
        [ Account::SyncInput.new(account: @account, family: @account.family, provider_sync: provider_sync,
          source_batch: source_batch, resource: "historical_balances", kind: "ibkr_equity", payload: handoff.payload) ]
      elsif retry_of
        unless retry_of.syncable_type == "Account" && retry_of.syncable_id == @account.id &&
            retry_of.account_family_id == @family_id && retry_of.terminal? && retry_of.account_inputs_sealed_at
          raise ArgumentError, "Retry requires a finalized calculation for this account"
        end
        retry_of.verify_account_inputs!
      else
        Account::SyncSource.where(account: @account).order(:resource).includes(:account_sync_input).map(&:account_sync_input)
      end
    end
end
