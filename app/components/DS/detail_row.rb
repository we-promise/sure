class DS::DetailRow < DesignSystemComponent
  # A label and its value on one line, label left and value right, inside a <dl>.
  # Extracted from the transaction drawer's "Additional details", which had this
  # exact dt/dd row hand-rolled seven times in one file (#3451 review) — the same
  # reason DS::Card and DS::EmptyState exist. The shape recurs across the
  # transfer, holding, budget-category and import-summary views, so reach for
  # this instead of repeating the class strings.
  #
  # The value may be given as a string or, when it needs its own markup (a link,
  # a logo, a privacy-sensitive figure), as a block:
  #
  #   <%= render DS::DetailRow.new(label: t(".payee"), value: sf[:payee]) %>
  #
  #   <%= render DS::DetailRow.new(label: t(".account")) do |row| %>
  #     <% row.with_value { link_to account.name, account } %>
  #   <% end %>
  renders_one :value

  ALIGNS = %i[start center baseline].freeze

  attr_reader :label, :plain_value, :align, :truncate, :value_class, :opts

  # @param label [String] the term, rendered in the <dt>
  # @param value [String, nil] the definition; omit when using the value slot
  # @param align [Symbol] cross-axis alignment, :start (default), :center or :baseline.
  #   :start is right for values that wrap to several lines; :center reads better
  #   for single-line pairs.
  # @param truncate [Boolean] clip the value to one line instead of wrapping.
  #   Off by default: wrapping keeps long provider values readable, where
  #   truncation hid them behind a title attribute.
  # @param value_class [String, nil] extra classes for the <dd>, e.g. "privacy-sensitive"
  # @param opts [Hash] forwarded to the wrapping div; :class merges with the base classes
  def initialize(label:, value: nil, align: :start, truncate: false, value_class: nil, **opts)
    @label = label
    @plain_value = value
    @align = ALIGNS.include?(align.to_sym) ? align.to_sym : :start
    @truncate = truncate
    @value_class = value_class
    @opts = opts
  end

  # @return [String] classes for the row, merging any class the caller passed
  def container_classes
    class_names("flex justify-between gap-2", "items-#{align}", opts[:class])
  end

  # Caller options minus :class, which container_classes has already merged.
  # Passing it twice would set the attribute twice.
  #
  # @return [Hash] attributes forwarded to the row element
  def container_opts
    opts.except(:class)
  end

  # shrink-0 keeps the label whole so the value is the side that gives way.
  #
  # @return [String] classes for the <dt>
  def label_classes
    class_names("text-secondary text-sm shrink-0")
  end

  # min-w-0 is load bearing, not decoration. A flex item's automatic minimum
  # width is its min-content width, and neither break-words nor truncate reduces
  # that, so an opaque value like a provider reference with no spaces would push
  # past the 550px drawer instead of wrapping, and truncate would never clip at
  # all. Letting the cell shrink is what lets either behavior happen.
  def value_classes
    class_names(
      "min-w-0 text-sm text-primary text-right",
      truncate ? "truncate" : "break-words",
      value_class
    )
  end
end
