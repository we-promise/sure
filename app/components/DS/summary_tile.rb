class DS::SummaryTile < DesignSystemComponent
  # One figure in a row of summary figures on a report section: a label over
  # the content (the figure and an optional note), on the inset surface.
  # Extracted from the availability report, which repeated the shell three
  # times; the other report sections hand-build the same tile.
  #
  #   <%= render DS::SummaryTile.new(label: t(".total")) do %>
  #     <p class="text-2xl font-semibold text-primary privacy-sensitive"><%= format_money(total) %></p>
  #   <% end %>
  def initialize(label:, **opts)
    @label = label
    @opts = opts
  end

  erb_template <<~ERB
    <%= content_tag :div, class: class_names("p-4 bg-surface-inset rounded-lg", @opts[:class]), **@opts.except(:class) do %>
      <p class="text-sm text-secondary mb-2"><%= @label %></p>
      <%= content %>
    <% end %>
  ERB
end
