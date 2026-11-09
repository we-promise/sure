# A group of the family's accounts at one institution, shown in the sidebar
# as one entry (BalanceSheet::AccountGroup::InstitutionBundle): the accounts
# sharing an institution name and URL. `key` is that pair, so the group is
# wherever those accounts are bundled.
#
# The row forms with the group (see .form) and keeps the group's own icon,
# taken from its first account then and kept as accounts join or change their
# own icons, and what the user set in its settings: a name and domain (blank
# follows the accounts) and the currency the total shows in.
#
# Saved with save_to_accounts, the name and domain, and the icon picked in the
# settings' icon picker (the account form's), are written onto the accounts
# themselves as well.
class InstitutionGroup < ApplicationRecord
  belongs_to :family

  # As an account's (Account::Logoable): a stored logo, which "brandfetch"
  # shows Brandfetch's icon for the domain over. Without either, the group
  # shows what its first account falls back to.
  has_one_attached :logo
  enum :logo_selection, { automatic: "automatic", brandfetch: "brandfetch" }, default: :automatic, prefix: :logo
  # The sidebar is cached by the groups' updated_at, which an attachment
  # alone does not change.
  before_save { self.updated_at = Time.current if attachment_changes.key?("logo") }

  normalizes :name, with: ->(name) { name.squish.presence }
  normalizes :institution_domain, with: ->(domain) { Account.normalize_institution_domain(domain) }
  normalizes :currency, with: ->(currency) { currency.strip.upcase.presence }

  validates :key, presence: true
  validates :key, uniqueness: { scope: :family_id }, if: -> { DatabaseTextValidator.acceptable?(key) }
  validates :name, :institution_domain, length: { maximum: 255 }, if: -> { DatabaseTextValidator.acceptable?([ name, institution_domain ]) }
  validates_with DatabaseTextValidator, attributes: %i[key name institution_domain currency]
  validates :currency, inclusion: { in: ->(_) { Money::Currency.as_options.map(&:iso_code) } }, allow_nil: true
  # Only a new upload: a logo shared from an account was checked there, or
  # stored before uploads were checked and must not block the group forming.
  validate :logo_is_small_raster_image, if: :logo_uploaded?

  # The name and domain the bundle takes from its accounts. The form shows
  # them filled in; saved unchanged, they stay blank, so the bundle keeps
  # following its accounts.
  attr_accessor :inherited_name, :inherited_domain

  # What the icon picker submitted (an Account::LogoChoice): saving gives it
  # to the group and every account written to.
  attr_writer :logo_choice

  # Set by Account::LogoChoice as on an account; a group fetches no icon of
  # its own to hold back.
  attr_accessor :logo_chosen

  before_validation :keep_inherited_values_blank

  # The institution an account is grouped by: its institution's name and
  # domain together, ignoring case and spacing. Accounts with neither are
  # never grouped. A domain holds no "|", so the pair reads back unambiguously.
  def self.key_for(account)
    name = account.institution_name.to_s.downcase.squish
    domain = Account.normalize_institution_domain(account.institution_domain).to_s
    "#{name}|#{domain}" if name.present? || domain.present?
  end

  # The row of the group `members` (two or more accounts sharing `key`, in
  # the viewing user's Default Account Order) form: the row saved for the key,
  # or else a new one taking the icon of the first of them (its logo, the same
  # blob, and whether it shows Brandfetch's instead). It is created the first
  # time the group is built, so a group of existing accounts, or one that forms
  # when a provider sync changes an account's institution, gets one too.
  # Returns nil when the row cannot be saved; the group then shows its first
  # account's icon.
  #
  # A guest's view saves nothing (`persist: false`): a read-only user must not
  # decide the icon the family's group keeps. It gets the same icon unsaved.
  def self.form(key, members, persist: !Current.user&.guest?)
    lead = members.first
    groups = lead.family.institution_groups
    existing = groups.find_by(key: key)
    return existing if existing
    return groups.new(key: key, logo_selection: lead.logo_selection).tap { |group| group.logo.attach(lead.logo.blob) if lead.logo.attached? } unless persist

    groups.create_or_find_by!(key: key) do |group|
      group.logo_selection = lead.logo_selection
      group.logo = lead.logo.blob if lead.logo.attached?
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.warn("InstitutionGroup could not form for family #{lead.family_id}: #{e.message}")
    nil
  end

  def logo_choice
    @logo_choice ||= Account::LogoChoice.new
  end

  # The domain the group's accounts share.
  def domain
    key.to_s.rpartition("|").last.presence
  end

  # The domain the group's icon comes from: the one saved here when its
  # accounts couldn't take it (none the user may edit), else theirs.
  def effective_domain(lead = nil)
    institution_domain.presence || lead&.institution_domain.presence || domain
  end

  def brandfetch_logo_url
    Account.brandfetch_logo_url_for(effective_domain)
  end

  # The group's icon as an account would hold it, for the account icon
  # partials and picker: an account (never saved) with the group's logo and
  # selection and the institution of `lead`, the group's first account.
  def logo_preview(lead, name: lead.name)
    preview = Account.new(family: family, name: name, institution_name: lead.institution_name,
                          institution_domain: effective_domain(lead), logo_selection: logo_selection)
    preview.logo.attach(logo.blob) if logo.attached?
    preview
  end

  # The key `accounts` led by `lead` will have once the settings are saved to
  # them (#save_to_accounts): the name and domain submitted, else theirs. A
  # rename onto another institution's key merges into it.
  def destination_key(lead)
    return key unless lead

    new_name = write_name?(name) ? name : lead.institution_name
    self.class.key_for(Account.new(institution_name: new_name, institution_domain: institution_domain.presence || lead.institution_domain))
  end

  # Saves the settings and writes the institution's name, domain and icon onto
  # `accounts` (the members the user may edit), so they all match, and the
  # icon onto the group. A new name moves the institution to a new key, and
  # the settings with it: into the row that key already has, if any (see
  # #move_to). Accounts and settings are saved together or not at all; a
  # picked icon is downloaded before.
  #
  # Returns the row holding the settings afterwards, or nil with the errors.
  def save_to_accounts(accounts)
    submitted = { name: name, institution_domain: institution_domain, key: key }
    return unless valid?

    first = accounts.first
    logo_choice.prepare(domain: submitted[:institution_domain] || first&.institution_domain || domain,
                        name: write_name?(submitted[:name]) || first.nil? ? submitted[:name] : first.institution_name,
                        family: family)

    transaction do
      group = self
      if accounts.any?
        accounts.each { |account| write_institution_to(account, submitted[:name], submitted[:institution_domain]) }
        # The accounts now carry the name and domain the bundle shows.
        self.name = self.institution_domain = nil
        group = move_to(self.class.key_for(accounts.first))
      end
      logo_choice.apply_to(group)
      group.save!
      logo_choice.finish
      group
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    assign_attributes(submitted)
    e.record.errors.full_messages.each { |message| errors.add(:base, message) } unless e.record.equal?(self)
    nil
  end

  private
    def keep_inherited_values_blank
      self.name = nil if name.present? && name == inherited_name
      self.institution_domain = nil if institution_domain.present? && institution_domain == inherited_domain
    end

    # As editing the account would: the domain change queues the usual logo
    # fetch unless an icon is picked here, and the edited fields are locked
    # against provider syncs.
    def write_institution_to(account, new_name, new_domain)
      account.institution_name = new_name if write_name?(new_name) && account.institution_name != new_name
      account.institution_domain = new_domain if new_domain && account.institution_domain != new_domain
      logo_choice.apply_to(account)
      return unless account.changed? || account.attachment_changes.any?

      account.save!
      account.lock_saved_attributes!
    end

    # A bundle of accounts without an institution name is named after their
    # domain; leaving that name as it is must not write the domain into their
    # names.
    def write_name?(new_name)
      new_name.present? && !(new_name == inherited_name && inherited_name == inherited_domain)
    end

    # The row the settings live in under `new_key`, to be saved. When another
    # row already holds that key, the two merge into it: the currency saved
    # here wins, and where it is left at the default, its own stays; its name
    # and domain go blank like this row's, since the accounts carry them now,
    # and it keeps its own icon unless one was picked here.
    def move_to(new_key)
      existing = family.institution_groups.where.not(id: id).find_by(key: new_key) if new_key != key
      unless existing
        self.key = new_key || key
        return self
      end

      existing.assign_attributes(name: nil, institution_domain: nil, currency: currency || existing.currency)
      destroy! if persisted?
      existing
    end

    def logo_uploaded?
      change = attachment_changes["logo"]
      change.respond_to?(:attachable) && !change.attachable.is_a?(ActiveStorage::Blob) && logo.attached?
    end

    # As for an account's upload (Account::Logoable).
    def logo_is_small_raster_image
      errors.add(:logo, :invalid_content_type) unless logo.content_type.in?(Account::LOGO_CONTENT_TYPES)
      errors.add(:logo, :too_large, max_size: Account::LOGO_MAX_SIZE / 1.megabyte) if logo.blob.byte_size > Account::LOGO_MAX_SIZE
    end
end
