class DS::Tabs::Nav < DesignSystemComponent
  erb_template <<~ERB
    <%# Neutral `<div>` host for `role="tablist"`. Per ARIA-in-HTML,
        `<nav>` has a fixed landmark role and may not be repurposed as
        a tablist — some AT implementations ignore the override and
        the child `role="tab"` elements end up parentless. The tab
        pattern is its own widget per WAI-ARIA APG; keyboard nav
        (ArrowLeft/Right, Home, End, Enter/Space) is driven by the
        Stimulus controller with the manual-activation pattern
        (focus moves first, activate on Enter/Space). %>
    <%= tag.div class: classes,
                role: "tablist",
                "aria-orientation": "horizontal" do %>
      <% btns.each do |btn| %>
        <%= btn %>
      <% end %>
    <% end %>
  ERB

  renders_many :btns, ->(id:, label:, classes: nil, &block) do
    is_active = id == active_tab
    content_tag(
      :button, label, id: "#{dom_prefix}-tab-#{id}",
      type: "button",
      class: class_names("focus-ring", btn_classes, is_active ? active_btn_classes : inactive_btn_classes, classes),
      role: "tab",
      "aria-selected": is_active.to_s,
      "aria-controls": "#{dom_prefix}-panel-#{id}",
      tabindex: is_active ? "0" : "-1",
      data: { id: id, action: "click->DS--tabs#show keydown->DS--tabs#handleKeydown", DS__tabs_target: "navBtn" },
      &block
    )
  end

  attr_reader :active_tab, :classes, :active_btn_classes, :inactive_btn_classes, :btn_classes, :dom_prefix

  def initialize(active_tab:, dom_prefix:, classes: nil, active_btn_classes: nil, inactive_btn_classes: nil, btn_classes: nil)
    @active_tab = active_tab
    @dom_prefix = dom_prefix
    @classes = classes
    @active_btn_classes = active_btn_classes
    @inactive_btn_classes = inactive_btn_classes
    @btn_classes = btn_classes
  end
end
