class CompactRowComponentPreview < ViewComponent::Preview
  # @param show_date toggle
  # @param show_balance toggle
  # @param show_notes toggle
  def default(show_date: true, show_balance: true, show_notes: false, muted: false, indent: false, header: false)
    render DS::CompactRow.new(show_date: show_date, show_balance: show_balance, show_notes: show_notes, muted: muted, indent: indent, header: header) do |row|
      row.with_checkbox { row.helpers.check_box_tag("preview_selection", "1", false, aria: { label: I18n.t("transactions.list.transaction") }) }
      row.with_date { header ? I18n.t("transactions.show.date_label") : row.helpers.format_date(Date.current) }
      row.with_primary { I18n.t("transactions.list.transaction") }
      row.with_notes { I18n.t("transactions.show.notes") }
      row.with_category { I18n.t("transactions.form.category_label") }
      row.with_amount { header ? I18n.t("transactions.show.amount") : row.helpers.format_money(Money.new(-10, "USD")) }
      row.with_balance { header ? I18n.t("accounts.show.activity.balance") : row.helpers.format_money(Money.new(1000, "USD")) }
    end
  end

  def header
    default(header: true)
  end

  def excluded
    default(muted: true)
  end

  def split_child
    default(indent: true)
  end

  def with_notes
    default(show_notes: true)
  end
end
