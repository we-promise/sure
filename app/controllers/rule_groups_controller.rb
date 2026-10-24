class RuleGroupsController < ApplicationController
  before_action :require_non_guest!
  before_action :set_rule_group, only: %i[edit update destroy reorder activation]

  def new
    @rule_group = Current.family.rule_groups.new
  end

  def create
    @rule_group = Current.family.rule_groups.new(rule_group_params)

    if @rule_group.save
      redirect_to rules_path, notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @rule_group.update(rule_group_params)
      redirect_to rules_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # The rules stay where they are, now without a group (see RuleGroup).
  def destroy
    @rule_group.destroy!
    redirect_to rules_path, notice: t(".success")
  end

  def reorder
    Rule::Layout.new(Current.family).reorder_group!(@rule_group, params.require(:rule_ids))
    head :no_content
  rescue ArgumentError
    head :unprocessable_entity
  end

  # Switches every rule of the group on or off. Not a state of the group: each
  # rule keeps its own switch.
  def activation
    active = ActiveModel::Type::Boolean.new.cast(params.require(:active))
    unchanged = @rule_group.switch_rules(active)

    if unchanged.any?
      redirect_to rules_path, alert: t(".partially_switched", count: unchanged.size)
    else
      redirect_to rules_path, notice: t(active ? ".activated" : ".deactivated", name: @rule_group.name)
    end
  end

  private
    def set_rule_group
      @rule_group = Current.family.rule_groups.find(params[:id])
    end

    def rule_group_params
      params.require(:rule_group).permit(:name)
    end
end
