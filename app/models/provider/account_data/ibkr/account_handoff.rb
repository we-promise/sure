# Call only after every required stream for this account has completed. Archive
# resolution is restricted to this logical provider sync and tolerates matching
# replay captures; it never uses a previous provider run or mutable sync_stats.
class Provider::AccountData::Ibkr::AccountHandoff
  def initialize(connection:, sync:, external_account:, writer_epoch:, fence:)
    @connection, @sync, @external = connection, sync, external_account
    @writer_epoch, @fence = writer_epoch, fence
  end

  def enqueue!
    account = @external.current_account
    raise Provider::AccountData::InvalidResponse, "IBKR account handoff has no linked account" unless account
    source = Provider::AccountData::Ibkr::Archive.build(connection: @connection, sync: @sync, observed_at: @sync.created_at)
    unless source.fetch(:source_batch_id)
      raise Provider::AccountData::IncompletePage, "IBKR account handoff has no original export"
    end
    handoff = Provider::AccountData::Ibkr::EquityCapture.new(connection: @connection, sync: @sync, external_account: @external,
      source_batch_id: source.fetch(:source_batch_id), writer_epoch: @writer_epoch, fence: @fence).capture!
    # Preparation can outlive its worker lease. Recheck it before the parent
    # lock closes cancellation's descendant-scan race and queues the child.
    @fence.call do
      @sync.with_lock do
        return if @sync.cancel_requested_at? || @sync.terminal?
        Account::SyncQueue.new(account).enqueue(parent_sync: @sync, window_start_date: @sync.window_start_date,
          window_end_date: @sync.window_end_date, handoff: handoff)
      end
    end
  end
end
