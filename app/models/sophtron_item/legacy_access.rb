# Sophtron's public legacy entrypoints share exact item/account admission. The
# session permit spans HTTP, but does not open a database transaction.
class SophtronItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence

  def self.with_item(item, operation: :ingest, sync: nil, allow_completed: false)
    Fence.with_item(item, operation: operation) do |current|
      current_sync = Fence.scoped_sync!(current, sync, allow_completed: allow_completed)
      yield current, current_sync
    end
  end

  def self.with_account(account, operation: :publish, sync: nil, allow_completed: false, allow_new: false)
    unless account.is_a?(SophtronAccount) && !account.destroyed? && (account.persisted? || allow_new)
      raise Fence::InvalidSource, "Expected a Sophtron account"
    end
    # Retain the caller's selected owner. Following the account's new item after
    # a reparent would authorize a stale request against a different connection.
    with_item(account.sophtron_item, operation: operation, sync: sync, allow_completed: allow_completed) do |item, current_sync|
      current = if account.new_record?
        account
      else
        Fence.scoped_accounts!(item, [ account ]).sole
      end
      current.sophtron_item = item
      yield current, current_sync
    end
  end
end
