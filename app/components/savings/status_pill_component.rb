class Savings::StatusPillComponent < ApplicationComponent
  VARIANTS = {
    on_track: { classes: "bg-green-500/10 text-success", icon: "check-circle", icon_color: "green" },
    behind:   { classes: "bg-yellow-500/10 text-warning", icon: "alert-triangle", icon_color: "yellow" },
    reached:  { classes: "bg-green-500/10 text-success", icon: "circle-check-big", icon_color: "green" },
    no_target_date: { classes: "bg-surface-inset text-secondary", icon: "calendar-off", icon_color: "default" }
  }.freeze

  def initialize(goal:)
    @goal = goal
  end

  def status
    @goal.status
  end

  def variant
    VARIANTS.fetch(status, VARIANTS[:no_target_date])
  end

  def label
    I18n.t("savings_goals.status.#{status}")
  end

  def icon_name
    variant[:icon]
  end

  def icon_color
    variant[:icon_color]
  end

  def classes
    variant[:classes]
  end
end
