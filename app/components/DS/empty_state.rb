class DS::EmptyState < DesignSystemComponent
  # Centered empty / no-data / disabled state: icon, title, optional
  # description, optional action slot. Replaces the repeated
  # `text-center py-12 + icon + title + description + CTA` markup across the
  # empty screens (#2137), and gives the bare-text feature-disabled pages a real
  # state instead of unstyled top-left text.
  #
  #   <%= render DS::EmptyState.new(icon: "repeat", title: "...", description: "...") do |es| %>
  #     <% es.with_action do %><%= render DS::Link.new(...) %><% end %>
  #   <% end %>
  renders_one :action

  def initialize(icon:, title:, description: nil, icon_size: "xl", **opts)
    @icon = icon
    @title = title
    @description = description
    @icon_size = icon_size
    @opts = opts
  end

  erb_template <<~ERB
    <%= content_tag :div,
          class: class_names("flex flex-col items-center text-center px-4 py-12", @opts[:class]),
          **@opts.except(:class) do %>
      <div class="mb-4"><%= helpers.icon(@icon, size: @icon_size) %></div>
      <p class="text-primary font-medium mb-2"><%= @title %></p>
      <% if @description.present? %>
        <p class="<%= class_names("text-secondary text-sm max-w-md", ("mb-4" if action?)) %>"><%= @description %></p>
      <% end %>
      <% if action? %><div><%= action %></div><% end %>
    <% end %>
  ERB
end
