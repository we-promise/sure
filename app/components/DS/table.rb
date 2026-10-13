class DS::Table < DesignSystemComponent
  # A data table: the card, horizontal scroll, header row, cell padding and row
  # rules in one place. Extracted because 25 views hand-built <table> markup in
  # five competing patterns, each with its own padding, dividers and header
  # style. The table renders every cell from its column definitions, so a
  # column's alignment is declared once, for its header and its cells, and
  # padding and borders can't drift from one table to the next.
  #
  #   <%= render DS::Table.new(rows: payments) do |table| %>
  #     <% table.with_column(t(".date")) { |payment| l(payment.date, format: :long) } %>
  #     <% table.with_column(t(".amount"), numeric: true, class: "privacy-sensitive") { |payment| format_money(payment.amount) } %>
  #   <% end %>
  #
  # A column's block is called with each row and its index. It has to output
  # markup or return a String: Rails' `capture` drops any other return value,
  # so a bare Integer renders as an empty cell (call `to_s` on it).
  renders_many :columns, ->(header, **options, &cell) do
    DS::Table::Column.new(header, cell: cell, sticky: sticky_header, **options)
  end

  attr_reader :rows, :inset, :sticky_header, :label, :row_class, :opts

  # @param rows [Enumerable] the records, one table row each
  # @param inset [Boolean] frame the table in container-inset, for a table that
  #   sits inside a card the way a list group does. A table on the page
  #   background is a card of its own.
  # @param sticky_header [Boolean] cap the height and keep the header row in view
  #   while the body scrolls under it, for long tables such as a loan schedule
  # @param label [String, nil] accessible name for the scroll area. Makes it a
  #   focusable region so a keyboard user can scroll a table that overflows;
  #   pass one whenever the table can scroll, including sideways on a narrow
  #   screen.
  # @param row_class [Proc, nil] called with each row, returns extra classes for
  #   its <tr>, e.g. the tint on a loan's past payments
  # @param opts [Hash] forwarded to the outer element; :class merges with the base classes
  def initialize(rows:, inset: false, sticky_header: false, label: nil, row_class: nil, **opts)
    @rows = rows
    @inset = inset
    @sticky_header = sticky_header
    @label = label
    @row_class = row_class
    @opts = opts
  end

  def container_classes
    class_names(("rounded-xl bg-container-inset p-1" if inset), opts[:class])
  end

  # Caller options minus :class, which container_classes has already merged.
  def container_opts
    opts.except(:class)
  end

  # `table-scroll` shows edge shadows while a wide table has more to scroll.
  # Its cover gradients default to container-inset, so scroll_opts points them
  # at the card's own background. Inside the inset frame the card takes the
  # frame's inner radius (xl less the 4px padding is lg); on its own it takes
  # DS::Card's.
  def scroll_classes
    class_names(
      "table-scroll shadow-border-xs",
      inset ? "rounded-lg" : "rounded-xl",
      ("max-h-128 overflow-y-auto" if sticky_header),
      ("focus-ring" if label)
    )
  end

  def scroll_opts
    attrs = { style: "--table-scroll-bg: var(--color-container)" }
    label ? attrs.merge(role: "region", tabindex: 0, aria: { label: label }) : attrs
  end

  def row_classes(row)
    row_class&.call(row)
  end
end
