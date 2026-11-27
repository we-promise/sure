module EtoroItemsHelper
  # The confirmation for deleting an eToro connection, from its card on the
  # Accounts page and from its panel under Settings. Deleting it deletes
  # Sure's records of its copy-trading portfolios, which eToro cannot send
  # again (EtoroItem#copies_recorded?), so while there are any it says so in
  # place of the entry point's own `fallback`.
  def etoro_item_deletion_confirm(etoro_item, fallback:)
    return fallback unless etoro_item.copies_recorded?

    CustomConfirm.new(
      title: t("etoro_items.deletion_confirm.title"),
      body: t("etoro_items.deletion_confirm.body"),
      btn_text: t("etoro_items.deletion_confirm.button"),
      destructive: true,
      high_severity: true
    )
  end
end
