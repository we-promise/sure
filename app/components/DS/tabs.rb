class DS::Tabs < DesignSystemComponent
  renders_one :nav, ->(classes: nil) do
    DS::Tabs::Nav.new(
      active_tab: active_tab,
      active_btn_classes: active_btn_classes,
      inactive_btn_classes: inactive_btn_classes,
      btn_classes: base_btn_classes,
      dom_prefix: dom_prefix,
      classes: unstyled? ? classes : class_names(nav_container_classes, classes)
    )
  end

  renders_many :panels, ->(tab_id:, &block) do
    content_tag(
      :div,
      class: ("hidden" unless tab_id == active_tab),
      role: "tabpanel",
      id: panel_dom_id(tab_id),
      "aria-labelledby": tab_dom_id(tab_id),
      tabindex: "0",
      data: { id: tab_id, DS__tabs_target: "panel" },
      &block
    )
  end

  # Scope tab/panel DOM ids to this component instance so multiple
  # `DS::Tabs` widgets on the same page (which often reuse generic
  # tab ids like "all" or "overview") don't collide and break the
  # `aria-controls` / `aria-labelledby` associations.
  def tab_dom_id(tab_id)
    "#{dom_prefix}-tab-#{tab_id}"
  end

  def panel_dom_id(tab_id)
    "#{dom_prefix}-panel-#{tab_id}"
  end

  VARIANTS = {
    default: {
      # `tab-item-active` is a Sure token utility (white light / gray-700 dark).
      # Swapping out the raw `bg-white theme-dark:bg-gray-700` removes the
      # last raw-palette reference in DS::Tabs.
      active_btn_classes: "tab-item-active text-primary shadow-sm",
      inactive_btn_classes: "text-secondary hover:bg-surface-inset-hover",
      base_btn_classes: "w-full inline-flex justify-center items-center text-sm font-medium px-2 py-1 rounded-md motion-safe:transition-colors motion-safe:duration-200",
      nav_container_classes: "flex bg-surface-inset p-1 rounded-lg mb-4"
    }
  }

  attr_reader :active_tab, :url_param_key, :session_key, :variant, :testid

  def initialize(active_tab:, url_param_key: nil, session_key: nil, variant: :default, active_btn_classes: "", inactive_btn_classes: "", testid: nil)
    @active_tab = active_tab
    @url_param_key = url_param_key
    @session_key = session_key
    @variant = variant.to_sym
    @active_btn_classes = active_btn_classes
    @inactive_btn_classes = inactive_btn_classes
    @testid = testid
  end

  def active_btn_classes
    unstyled? ? @active_btn_classes : VARIANTS.dig(variant, :active_btn_classes)
  end

  def inactive_btn_classes
    unstyled? ? @inactive_btn_classes : VARIANTS.dig(variant, :inactive_btn_classes)
  end

  private
    def dom_prefix
      @dom_prefix ||= "tabs-#{object_id}"
    end

    def unstyled?
      variant == :unstyled
    end

    def base_btn_classes
      unless unstyled?
        VARIANTS.dig(variant, :base_btn_classes)
      end
    end

    def nav_container_classes
      unless unstyled?
        VARIANTS.dig(variant, :nav_container_classes)
      end
    end
end
