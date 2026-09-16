module Breadcrumbable
  extend ActiveSupport::Concern

  included do
    helper_method :breadcrumbs
  end

  private
    # Render-time helper so I18n.locale (set by Localize's around_action) is
    # already in effect when the breadcrumb labels are translated.
    # Controllers can still override by assigning @breadcrumbs in their action.
    def breadcrumbs
      @breadcrumbs || default_breadcrumbs
    end

    def default_breadcrumbs
      [
        [ I18n.t("breadcrumbs.home"), root_path ],
        [ I18n.t("breadcrumbs.#{controller_name}", default: controller_name.titleize), nil ]
      ]
    end

    # Trail prefix for pages living under the Plan hub (budgets, goals).
    # Preview users reach them through /plan, so their trail starts
    # Home > Plan; without the flag it's the plain Home prefix.
    def plan_breadcrumb_prefix
      prefix = [ [ I18n.t("breadcrumbs.home"), root_path ] ]
      prefix << [ I18n.t("breadcrumbs.plan"), plan_path ] if preview_features_enabled?
      prefix
    end
end
