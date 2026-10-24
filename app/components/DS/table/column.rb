class DS::Table::Column < DesignSystemComponent
  # One column of a DS::Table: its header cell, and how to render its cell in
  # each row. Declared with `table.with_column`; the table renders it.
  ALIGNS = %i[left right].freeze

  attr_reader :header

  # @param header [String] the column heading
  # @param cell [Proc] renders the cell for a row, given the row and its index
  # @param sticky [Boolean] set by the table when its header row is sticky
  # @param align [Symbol] :left (default) or :right, for the header and the cells
  # @param numeric [Boolean] a column of figures: right-aligned, tabular digits,
  #   never wrapped mid-number. Implies align: :right.
  # @param row_header [Boolean] render the cells as <th scope="row">, for the
  #   column that names each row
  # @param class [String, nil] extra classes for the body cells, e.g. "text-secondary"
  #   or "privacy-sensitive"
  def initialize(header, cell:, sticky: false, align: :left, numeric: false, row_header: false, class: nil)
    @header = header
    @cell = cell
    @sticky = sticky
    @numeric = numeric
    # to_s first so a nil or unrecognized value falls back instead of raising.
    candidate = align.to_s.to_sym
    @align = numeric ? :right : (ALIGNS.include?(candidate) ? candidate : :left)
    @row_header = row_header
    @cell_class = binding.local_variable_get(:class)
  end

  # The header cell. Its rule is the table's only full-weight line, left to do
  # the one job a line is good at, separating the labels from the data; the
  # rows use the subdued rule between them.
  def call
    tag.th header, scope: "col", class: class_names(
      "px-4 py-3 border-b border-divider text-xs uppercase font-medium text-secondary",
      alignment_classes,
      # z-10 so a privacy-blurred amount, which paints in a layer of its own,
      # doesn't show through the header as it scrolls under it.
      ("sticky top-0 z-10 bg-container" if @sticky)
    )
  end

  # The cell for one row. The first row has no top rule: the header's is right above it.
  def cell(row, index)
    content_tag(
      @row_header ? :th : :td,
      @cell&.call(row, index),
      scope: ("row" if @row_header),
      class: class_names(
        "px-4 py-3",
        ("border-t border-subdued" if index.positive?),
        ("font-medium" if @row_header),
        alignment_classes,
        @cell_class
      )
    )
  end

  private
    def alignment_classes
      class_names(
        @align == :right ? "text-right" : "text-left",
        ("tabular-nums whitespace-nowrap" if @numeric)
      )
    end
end
