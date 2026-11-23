module PurchasesHelper
  # One review note on a purchase, with the numbers when a total didn't add up.
  def purchase_review_reason(purchase, reason)
    key = reason["reason"].to_s
    if key == "items_mismatch" && reason["items"]
      money = ->(value) { purchase_amount(purchase, BigDecimal(value.to_s)) }
      t("purchases.review_reasons.items_mismatch_detail",
        items: money.(reason["items"]), shipping: money.(reason["shipping"]), discount: money.(reason["discount"]),
        expected: money.(reason["expected"]), actual: money.(reason["actual"]))
    else
      t("purchases.review_reasons.#{key}", default: key.humanize)
    end
  end

  # "November 2026" for a month group's heading; languages where a month named on its own takes
  # another form than in a date (Polish "Listopad", not "listopada") give it as standalone names.
  def purchase_month_title(month)
    names = I18n.t("date.standalone_month_names", default: nil) || I18n.t("date.month_names")
    "#{names[month.month]} #{month.year}"
  end

  # A purchase amount formatted for the page; an unknown currency shows the amount as read.
  def purchase_amount(purchase, amount)
    purchase.amount_text(amount, formatter: ->(money) { format_money(money) })
  end

  # The shop's logo: Brandfetch by the shop's domain, else the linked transaction's merchant logo.
  def purchase_logo_url(purchase)
    Setting.brand_fetch_icon_url(purchase.merchant_domain) ||
      purchase.linked_transaction&.merchant&.logo_url.presence&.then { Setting.transform_brand_fetch_url(_1) }
  end

  # "2×" for an item bought twice; nil when the email didn't say how many.
  def purchase_item_quantity(item)
    "#{item.quantity.to_s("F").delete_suffix(".0")}×" if item.quantity
  end

  # The three tiles above the purchases list: label, value (with its colour) and caption.
  def purchase_summary_tiles(summary)
    spent = safe_join([
      format_money(summary.spent),
      (tag.span("+ #{summary.other_spent.map { format_money(_1) }.join(" + ")}", class: "text-sm text-secondary") if summary.other_spent.any?)
    ].compact, " ")
    waiting = summary.to_match_count.positive?

    [
      { label: t("purchases.summary.this_month"), value: spent, value_class: "text-primary privacy-sensitive",
        caption: "#{t("purchases.summary.purchases", count: summary.purchases_count)} · #{t("purchases.summary.items", count: summary.items_count)}" },
      { label: t("purchases.summary.to_match"), value: summary.to_match_count, value_class: waiting ? "text-warning" : "text-primary",
        caption: waiting ? t("purchases.summary.to_match_waiting") : t("purchases.summary.to_match_none") },
      { label: t("purchases.summary.top_merchant"), value: summary.top_merchant || "—", value_class: "text-primary",
        caption: summary.top_merchant ? t("purchases.summary.top_merchant_orders", count: summary.top_merchant_count) : t("purchases.summary.top_merchant_none") }
    ]
  end
end
