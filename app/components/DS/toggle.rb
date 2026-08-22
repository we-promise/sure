class DS::Toggle < DesignSystemComponent
  attr_reader :id, :name, :checked, :disabled, :checked_value, :unchecked_value, :opts

  def initialize(id:, name: nil, checked: false, disabled: false, checked_value: "1", unchecked_value: "0", **opts)
    @id = id
    @name = name
    @checked = checked
    @disabled = disabled
    @checked_value = checked_value
    @unchecked_value = unchecked_value
    @opts = opts
  end

  def label_classes
    class_names(
       "relative block w-9 h-5 cursor-pointer",
       # `bg-toggle-track` lifts the dark-mode off-track to gray-700 so the
       # switch keeps WCAG 1.4.11 contrast against the surrounding
       # bg-container (gray-900). `bg-surface-inset` resolves to gray-800
       # in dark mode and dropped to ~1.5:1 against the container,
       # making the toggle nearly invisible inside modals.
       "rounded-full bg-toggle-track",
       # `motion-safe:` gates the bg + thumb-translate transitions on
       # `prefers-reduced-motion`; reduced-motion users get a snap.
       "motion-safe:transition-colors motion-safe:duration-300",
       "after:content-[''] after:block after:bg-white after:absolute after:rounded-full",
       "after:top-0.5 after:left-0.5 after:w-4 after:h-4 after:shadow-sm",
       "motion-safe:after:transition-transform motion-safe:after:duration-300 motion-safe:after:ease-in-out",
       "peer-checked:bg-success peer-checked:after:translate-x-4",
       # Canonical focus ring (#2136), driven from the sr-only input via
       # `peer-focus-visible:`. outline-offset places it just outside the track
       # so it lands on surrounding chrome in either theme.
       "peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-focus-ring",
       "peer-disabled:opacity-70 peer-disabled:cursor-not-allowed"
    )
  end
end
