module BitcoinWalletsHelper
  def bitcoin_wallet_management_allowed?(account, permission)
    preview_features_enabled? && Current.user&.admin? && account.crypto? &&
      permission.in?([ :owner, :full_control ])
  end

  def format_quantity_change(quantity)
    "#{'+' if quantity.positive?}#{format_quantity(quantity, exact: true)}"
  end
end
