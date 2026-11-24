# A labelled figure: a small label, the figure itself, and an optional hint
# beneath. For headline numbers such as a financial independence number or
# the chance a plan's money lasts. Use DS::DetailRow for a label and value
# on one line.
#
#   <%= render DS::Stat.new(label: t(".fi_number"), value: money, hint: t(".explainer"), size: :xl) %>
#
# When the value is not a single figure, a sentence say, pass it as a block
# and it renders as given:
#
#   <%= render DS::Stat.new(label: t(".confident_year")) do |stat| %>
#     <% stat.with_value { tag.p(t(".none"), class: "text-sm text-warning") } %>
#   <% end %>
class DS::Stat < DesignSystemComponent
  SIZES = { lg: "text-2xl", xl: "text-3xl" }.freeze
  TONES = { primary: "text-primary", success: "text-success", warning: "text-warning" }.freeze

  renders_one :value

  attr_reader :label, :plain_value, :hint, :opts

  # @param label [String] what the figure is
  # @param value [String, nil] the figure; omit when using the value slot
  # @param hint [String, nil] a line of context beneath the figure
  # @param size [Symbol] :lg (default) or :xl, for a page's lead figure
  # @param tone [Symbol] :primary (default), :success or :warning
  # @param value_class [String, nil] extra classes for the figure, e.g. "privacy-sensitive"
  # @param value_opts [Hash] attributes for the figure's element, e.g. data;
  #   a :class adds to the figure's classes
  # @param hint_class [String, nil] extra classes for the hint, e.g. "privacy-sensitive"
  #   when it carries an amount
  # @param opts [Hash] forwarded to the wrapping div
  def initialize(label:, value: nil, hint: nil, size: :lg, tone: :primary, value_class: nil, value_opts: {}, hint_class: nil, **opts)
    @label = label
    @plain_value = value
    @hint = hint
    @size = SIZES.key?(size.to_s.to_sym) ? size.to_s.to_sym : :lg
    @tone = TONES.key?(tone.to_s.to_sym) ? tone.to_s.to_sym : :primary
    @value_class = value_class
    @value_opts = value_opts
    @hint_class = hint_class
    @opts = opts
  end

  def value_classes
    class_names("font-medium tabular-nums", SIZES.fetch(@size), TONES.fetch(@tone), @value_class, @value_opts[:class])
  end

  # The figure's attributes other than :class, which value_classes has merged.
  def value_attributes
    @value_opts.except(:class)
  end

  def hint_classes
    class_names("text-xs text-subdued mt-1", @hint_class)
  end
end
