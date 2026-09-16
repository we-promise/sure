class AkahuItem::LegacyAccess < Provider::AccountData::LegacyAccess
  def self.provider_key
    "akahu"
  end

  def self.transport_columns
    %w[id family_id app_token user_token sync_start_date]
  end

  def self.source_columns
    %w[id akahu_item_id account_id account_type account_status currency current_balance available_balance balance_limit sync_start_date]
  end
end
