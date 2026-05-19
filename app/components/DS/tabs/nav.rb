class DS::Tabs::Nav < DesignSystemComponent
  erb_template <<~ERB
    <%# `role="tablist"` overrides the implicit `<nav>` landmark — the
        tab pattern is its own widget per WAI-ARIA APG and shouldn't
        announce as a navigation landmark. Keyboard navigation
        (ArrowLeft/Right, Home, End, Enter/Space) is driven by the
        Stimulus controller; manual activation pattern (focus moves
        first, activate on Enter/Space). %>
    <%= tag.nav class: classes,
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
      :button, label, id: id,
      type: "button",
      class: class_names(btn_classes, is_active ? active_btn_classes : inactive_btn_classes, classes),
      role: "tab",
      "aria-selected": is_active.to_s,
      "aria-controls": "panel-#{id}",
      tabindex: is_active ? "0" : "-1",
      data: { id: id, action: "click->DS--tabs#show keydown->DS--tabs#handleKeydown", DS__tabs_target: "navBtn" },
      &block
    )
  end

  attr_reader :active_tab, :classes, :active_btn_classes, :inactive_btn_classes, :btn_classes

  def initialize(active_tab:, classes: nil, active_btn_classes: nil, inactive_btn_classes: nil, btn_classes: nil)
    @active_tab = active_tab
    @classes = classes
    @active_btn_classes = active_btn_classes
    @inactive_btn_classes = inactive_btn_classes
    @btn_classes = btn_classes
  end
end
