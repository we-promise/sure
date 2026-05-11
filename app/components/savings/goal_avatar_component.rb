class Savings::GoalAvatarComponent < ApplicationComponent
  SIZES = {
    "sm" => { box: "w-6 h-6", text: "text-xs" },
    "md" => { box: "w-8 h-8", text: "text-sm" },
    "lg" => { box: "w-12 h-12", text: "text-lg" }
  }.freeze

  def initialize(goal: nil, name: nil, color: nil, size: "md")
    @goal = goal
    @name = name || goal&.name
    @color = color || goal&.color || SavingsGoal::COLORS.first
    @size = SIZES.key?(size) ? size : "md"
  end

  attr_reader :color

  def initial
    return "?" if @name.blank?
    @name.strip.first&.upcase || "?"
  end

  def box_classes
    SIZES[@size][:box]
  end

  def text_classes
    SIZES[@size][:text]
  end
end
