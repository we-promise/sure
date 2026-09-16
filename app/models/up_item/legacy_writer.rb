# Up's public account commands keep the source selected by their caller, but
# reload both its payload and financial link after acquiring the item fence.
class UpItem::LegacyWriter
  Fence = Provider::AccountData::LegacyWriterFence

  def self.with_account(account, operation: :publish)
    unless account.is_a?(UpAccount) && account.persisted?
      raise Fence::InvalidSource, "Expected a persisted Up account"
    end

    Fence.with_item(account.up_item, operation: operation) do |item|
      current = Fence.scoped_accounts!(item, [ account ]).fetch(0)
      yield current
    end
  end
end
