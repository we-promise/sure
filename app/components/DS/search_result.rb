class DS::SearchResult < DesignSystemComponent
  # One option in a list of search results: an icon, a title and a subtitle
  # naming where the result lives. The settings search lists both pages and
  # individual settings with it. Its script fills a row in from the
  # `data-slot` hooks, so a row can be rendered empty and completed later.
  #
  #   <%= render DS::SearchResult.new(href: path, title: "Security", subtitle: "Account", icon: "shield") %>
  BASE_CLASSES = "flex items-center gap-3 px-3 py-2 rounded-lg text-sm focus-ring hover:bg-surface-hover aria-selected:bg-surface-hover".freeze

  attr_reader :href, :title, :subtitle, :icon, :opts

  # @param href [String] where the result leads
  # @param title [String, nil] the result's own name
  # @param subtitle [String, nil] secondary line, such as the section or page it belongs to
  # @param icon [String, nil] icon name
  # @param opts [Hash] forwarded to the link; :class merges with the base classes
  def initialize(href:, title: nil, subtitle: nil, icon: nil, **opts)
    @href = href
    @title = title
    @subtitle = subtitle
    @icon = icon
    @opts = opts
  end

  # @return [String] classes for the link, merging any class the caller passed
  def container_classes
    class_names(BASE_CLASSES, opts[:class])
  end

  # Caller options minus :class, which container_classes has already merged.
  #
  # @return [Hash] attributes forwarded to the link
  def container_opts
    opts.except(:class)
  end
end
