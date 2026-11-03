module MoomooItemsHelper
  # "SG • Margin • ••3456 • SGD" for the setup and link dialogs.
  def moomoo_account_details(moomoo_account)
    firm = moomoo_account.security_firm
    [
      (t("moomoo_items.defaults.firms.#{firm}", default: firm) if firm.present?),
      (t("moomoo_items.acc_types.#{moomoo_account.acc_type}", default: moomoo_account.acc_type.humanize) if moomoo_account.acc_type.present?),
      moomoo_account.account_number_mask,
      moomoo_account.currency
    ].compact_blank.join(" • ")
  end

  def moomoo_account_balance(moomoo_account)
    Money.new(moomoo_account.current_balance || 0, moomoo_account.currency.presence || Current.family.currency).format
  end
end
