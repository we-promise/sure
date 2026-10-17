class CompactRowComponentPreview < ViewComponent::Preview
  # @param show_date toggle
  # @param show_balance toggle
  # @param show_notes toggle
  def default(show_date: true, show_balance: true, show_notes: false, muted: false, indent: false, header: false)
    render_with_template(template: "compact_row_component_preview/default", locals: { show_date:, show_balance:, show_notes:, muted:, indent:, header: })
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
