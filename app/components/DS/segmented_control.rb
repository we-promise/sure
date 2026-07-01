class DS::SegmentedControl < DesignSystemComponent
  # A single-select pill group — filters, mode switches, compact view toggles.
  # NOT the full ARIA tab/panel widget; use DS::Tabs for tabs-with-panels.
  #
  # Each segment is a link (pass `href:`) or a button (default — pass `data:`
  # for a Stimulus-driven control). Mark the current one with `active: true`.
  # The selected style lives in `.segmented-control__segment--active`, so a
  # controller can toggle selection by flipping that one class.
  #
  # `full_width: true` stretches segments to equal width (the "equal-footprint"
  # the #2137 audit asked for); default is content width.
  renders_many :segments, ->(label, active: false, href: nil, **opts) do
    # `focus-ring` is for link segments — button segments already get the
    # canonical outline from the base-layer button rule (it's an idempotent
    # duplicate there).
    classes = class_names(
      "segmented-control__segment focus-ring",
      ("flex-1" if full_width),
      ("segmented-control__segment--active" if active),
      opts.delete(:class)
    )

    # Expose the selected state to assistive tech: link segments use
    # `aria-current`, button segments use `aria-pressed`. A Stimulus
    # controller that toggles `--active` should mirror these (see
    # budget_filter_controller#filterValueChanged).
    if href
      link_to(label, href, class: classes, "aria-current": (active ? "true" : nil), **opts)
    else
      content_tag(:button, label, type: "button", class: classes, "aria-pressed": active.to_s, **opts)
    end
  end

  attr_reader :full_width, :aria_label

  def initialize(full_width: false, aria_label: nil, **opts)
    @full_width = full_width
    @aria_label = aria_label
    @opts = opts
  end

  erb_template <<~ERB
    <%= content_tag :div,
          class: class_names("segmented-control", ("w-full" if full_width), @opts[:class]),
          role: "group",
          "aria-label": aria_label,
          **@opts.except(:class) do %>
      <% segments.each do |segment| %><%= segment %><% end %>
    <% end %>
  ERB
end
