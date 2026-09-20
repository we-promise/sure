class DS::Note < DesignSystemComponent
  attr_reader :title, :opts

  # Quiet inset panel for standing explanatory copy — a data-sharing notice, a
  # retention policy, a "what this setting actually does" aside.
  #
  # Distinct from DS::Alert, which carries a semantic variant and an ARIA live
  # region: this is static prose that was always on the page, not something that
  # just became true, so announcing it would be wrong. Distinct from DS::Card,
  # which is a raised surface (rounded-xl, shadow) rather than an inset one.
  #
  # Extracted from the provider selectors in settings/hostings, which had this
  # exact shell hand-rolled twice.
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
