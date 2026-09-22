# Quiet inset panel for standing explanatory copy, such as a data-sharing notice
# or a retention policy. Use DS::Alert instead for something that just became
# true, since it announces through an ARIA live region. Use DS::Card for a
# raised surface rather than an inset one.
class DS::Note < DesignSystemComponent
  attr_reader :title, :opts

  def initialize(title: nil, **opts)
    @title = title
    @opts = opts
  end

  def container_classes
    class_names(
      "rounded-md border border-secondary p-3 bg-container-inset text-xs text-secondary space-y-1",
      opts[:class]
    )
  end

  def container_opts
    opts.except(:class)
  end
end
