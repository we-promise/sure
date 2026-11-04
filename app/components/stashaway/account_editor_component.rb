class Stashaway::AccountEditorComponent < ApplicationComponent
  def initialize(family:, items: nil, new_item: nil)
    @family = family
    @items = items || family.stashaway_items.active.ordered
    @new_item = new_item
  end

  attr_reader :items

  # The add form keeps the email of a sign-in StashAway refused.
  def new_item
    @new_item || @family.stashaway_items.build
  end

  def region_options
    Provider::Stashaway::Region::ALL.map { |region| [ region.label, region.code ] }
  end

  def state_for(item)
    if item.login_pending?
      :code
    elsif item.ready_for_sync?
      :connected
    else
      :sign_in
    end
  end

  # The password is kept encrypted or not at all, so keeping it is offered
  # only when encryption is configured; the panel's warning says so.
  def password_can_be_kept?
    StashawayItem.encryption_ready?
  end

  # The opt-in to keep the password, on the sign-in and connect forms alike;
  # nothing while it cannot be kept.
  def remember_password_field(form, checked: false)
    return unless password_can_be_kept?

    tag.div(class: "flex items-center gap-2") do
      safe_join([
        form.check_box(:remember_password, class: "checkbox checkbox--light", checked: checked),
        form.label(:remember_password, translation("remember_password_label"), class: "text-sm text-secondary cursor-pointer select-none")
      ])
    end
  end

  def translation(key, **options)
    helpers.t("settings.providers.stashaway_panel.#{key}", **options)
  end
end
