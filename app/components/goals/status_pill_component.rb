class Goals::StatusPillComponent < ApplicationComponent
  # Text colors here intentionally use palette steps (green/yellow/gray-700)
  # instead of the `text-success` / `text-warning` / `text-secondary` tokens
  # because the functional tokens drop below WCAG 1.4.3 4.5:1 on tinted
  # surfaces in light mode (~2.88:1 / 3.0:1 / 4.16:1). Each variant carries
  # a theme-dark: override so the dark-700 text doesn't disappear against
  # the dark-mode tinted surface. Local override only; revert once
  # we-promise/sure#1736 lands token-level fixes.
  VARIANTS = {
    on_track: { classes: "bg-green-500/10 text-green-700 theme-dark:text-green-300", icon: "circle-check" },
    behind: { classes: "bg-yellow-500/10 text-yellow-700 theme-dark:text-yellow-300", icon: "triangle-alert" },
    reached: { classes: "bg-green-500/10 text-green-700 theme-dark:text-green-300", icon: "star" },
    completed: { classes: "bg-green-500/10 text-green-700 theme-dark:text-green-300", icon: "circle-check-big" },
    no_target_date: { classes: "bg-surface-inset text-gray-700 theme-dark:text-gray-200", icon: "infinity" },
    paused: { classes: "bg-surface-inset text-gray-700 theme-dark:text-gray-200", icon: "pause" },
    archived: { classes: "bg-surface-inset text-gray-700 theme-dark:text-gray-200", icon: "archive" }
  }.freeze

  def initialize(goal:)
    @goal = goal
  end

  def status_key
    @goal.display_status
  end

  def variant
    VARIANTS.fetch(status_key, VARIANTS[:no_target_date])
  end

  def label
    I18n.t("goals.status.#{status_key}")
  end

  def classes
    variant[:classes]
  end

  def icon_name
    variant[:icon]
  end
end
