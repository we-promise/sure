class AkahuItem::SyncRequest < Provider::AccountData::LegacySyncRequest
  def self.provider_key
    "akahu"
  end
end
