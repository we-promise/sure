class DS::ActionRow < DesignSystemComponent
  # A full-width row button for actions inside pickers, dropdowns and lists:
  # `Create "Groceries"`, "Add as a subcategory…", "Back", or a pickable item
  # whose content (e.g. a category badge) is passed as the block.
  #
  # Rows reserve a fixed-width leading gutter (the icon slot) so their labels
  # line up with the list rows around them whether or not an icon is shown.
  #
  # - `tone: :primary` for the main action in a list, `:secondary` for
  #   supporting ones.
  # - `hidden: true` renders it hidden (`hidden`, not `flex`); a Stimulus
  #   controller reveals it by swapping those two classes.
  # - Any other options (`data:`, `aria:`, `title:`, `disabled:`) go on the
  #   `<button>`.
  TONES = %i[primary secondary].freeze

  attr_reader :text, :icon, :tone, :hidden, :opts

  def initialize(text: nil, icon: nil, tone: :primary, hidden: false, **opts)
    @text = text
    @icon = icon
    @tone = TONES.include?(tone.to_sym) ? tone.to_sym : :primary
    @hidden = hidden
    @opts = opts
  end

  def classes
    class_names(
      "items-center gap-1.5 w-full rounded-lg px-2 py-1.5 text-sm text-left cursor-pointer",
      "hover:bg-container-inset-hover focus-ring disabled:opacity-50 disabled:cursor-not-allowed",
      tone == :primary ? "font-medium text-primary" : "text-secondary",
      hidden ? "hidden" : "flex",
      opts[:class]
    )
  end

  erb_template <<~ERB
    <%= content_tag :button, type: "button", class: classes, **opts.except(:class) do %>
      <span class="flex items-center justify-center w-5 h-5 shrink-0"><%= helpers.icon(icon, size: "sm", color: "current") if icon %></span>
      <% if content? %><%= content %><% else %><span class="min-w-0 truncate"><%= text %></span><% end %>
    <% end %>
  ERB
end
