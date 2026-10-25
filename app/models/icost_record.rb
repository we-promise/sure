class IcostRecord < ApplicationRecord
  ResolutionError = Class.new(StandardError)

  belongs_to :icost_import
  belongs_to :family
  belongs_to :entry, optional: true
  belongs_to :counterpart_entry, class_name: "Entry", optional: true

  validates :source_id, :row_sha256, :source_row, presence: true
  validates :status, inclusion: { in: %w[ready needs_review published] }
  validates :source_id, uniqueness: { scope: :family_id }
  validate :same_family

  scope :owned_by, ->(user) { joins(:icost_import).where(family_id: user.family_id, icost_imports: { user_id: user.id }) }

  attr_readonly :icost_import_id, :family_id, :source_row, :source_id, :row_sha256,
    :source_values, :raw_fields, :unknown_fields, :recorded_at_text, :transaction_type,
    :amount, :currency, :category_path, :account_name, :counterparty_name, :book_name,
    :note, :tags, :location_text, :latitude, :longitude, :coordinate_system,
    :refund_amount, :discount_amount, :fee_amount, :image_references

  def stage!(user:)
    authorize!(user)
    return self if persisted?
    self.issues += [ "currency_unsupported" ] unless Money::Currency.all.key?(currency.to_s.downcase)
    if issues.empty?
      candidates = legacy_entries(user)
      if candidates.one? && legacy_matches?(candidates.first)
        self.entry = candidates.first
        self.status = "published"
      elsif candidates.any?
        self.issues += [ "existing_entry_mismatch" ]
      elsif family.icost_imports.where.not(id: icost_import_id).joins(:records)
          .where(icost_records: { row_sha256: row_sha256, status: "published" }).exists?
        self.issues += [ "possible_duplicate_source" ]
      elsif (account = matching_account(user)).nil?
        self.issues += [ "account_mapping_required" ]
      elsif !local_valuation_safe?(account)
        self.issues += [ "account_valuation_requires_review" ]
      end
    end
    self.status = issues.empty? ? (entry ? "published" : "ready") : "needs_review"
    save!
  end

  # Review edits are an audit trail separate from immutable source fields. They
  # never publish transactions; publishing remains a separate previewed action.
  def resolve!(user:, attributes:)
    authorize!(user)
    with_lock do
      raise ResolutionError, "already_published" if status == "published"
      attrs = attributes.to_h.stringify_keys.slice("account_id", "from_account_id", "to_account_id", "review_note")
      self.review_note = attrs.delete("review_note") if attrs.key?("review_note")
      attrs.reject! { |_, value| value.blank? }
      attrs.each_value { |id| writable_account!(user, id) }
      self.resolution = resolution.merge(attrs)
      if resolution["account_id"].present? && %w[支出 收入].include?(transaction_type)
        self.issues -= %w[account_required account_mapping_required]
      end
      if transaction_type == "转账" && resolution.values_at("from_account_id", "to_account_id").all?(&:present?)
        raise ResolutionError, "different_accounts_required" if resolution["from_account_id"] == resolution["to_account_id"]
        self.issues -= %w[transfer_direction_required account_required counterparty_required]
      end
      selected_accounts = resolution.values_at("account_id", "from_account_id", "to_account_id").compact.map { |id| writable_account!(user, id) }
      self.issues -= [ "account_valuation_requires_review" ] if selected_accounts.any?
      self.issues |= [ "account_valuation_requires_review" ] unless selected_accounts.all? { |account| local_valuation_safe?(account) }
      self.status = issues.empty? ? "ready" : "needs_review"
      save!
    end
    self
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ResolutionError
    reload if persisted?
    raise ResolutionError, "invalid_resolution"
  end

  def publish!(user:)
    authorize!(user)
    family.with_lock { perform_publish!(user) }
  end

  def ledger_date
    Date.strptime(recorded_at_text.to_s.strip[0, 10].tr("/", "-"), "%Y-%m-%d")
  end

  def self.valid_coordinates(latitude, longitude)
    values = [ latitude, longitude ].map { |value| BigDecimal(value.to_s, exception: false) }
    return unless values.all? { |value| value&.finite? }
    return unless values.first.abs <= 90 && values.last.abs <= 180
    values.map(&:to_f)
  end

  def map_coordinates
    location = resolution["location"]
    return self.class.valid_coordinates(location["latitude"], location["longitude"]) if location.is_a?(Hash)
    return unless %w[wgs84 wgs-84 epsg:4326].include?(coordinate_system.to_s.downcase)
    self.class.valid_coordinates(latitude, longitude)
  end

  def self.locate_place!(user:, place:, latitude:, longitude:)
    IcostImport.authorize!(user.family, user)
    coordinates = valid_coordinates(latitude, longitude)
    raise ResolutionError, "invalid_coordinates" unless coordinates && place.present?
    user.family.with_lock do
      owned_by(user).where(location_text: place).find_each do |record|
        record.with_lock do
          record.update!(resolution: record.resolution.merge("location" => {
            "latitude" => coordinates.first, "longitude" => coordinates.last,
            "coordinate_system" => "WGS84", "source" => "user_confirmed_place"
          }))
        end
      end
    end
  end

  def self.confirmed_locations(user)
    owned_by(user).where("resolution ? 'location'").pluck(:location_text, :resolution)
      .group_by(&:first).filter_map do |place, rows|
        locations = rows.map { |_name, resolution| resolution["location"] }.uniq
        [ place, locations.sole ] if place.present? && locations.one?
      end.to_h
  end

  def self.confirmed_account_mappings(user)
    owned_by(user).where("resolution ? 'account_id'").pluck(:account_name, :currency, :resolution)
      .group_by { |name, currency, _resolution| [ name, currency ] }.filter_map do |key, rows|
        ids = rows.map { |_name, _currency, resolution| resolution["account_id"] }.uniq
        [ key, ids.sole ] if key.first.present? && ids.one?
      end.to_h
  end

  private
    def perform_publish!(user)
      with_lock(requires_new: true) do
        return self if status == "published"
        raise ResolutionError, "review_required" unless status == "ready" && issues.empty?
        if IcostRecord.where(family_id: family_id, row_sha256: row_sha256, status: "published")
            .where.not(icost_import_id: icost_import_id).exists?
          update!(status: "needs_review", issues: (issues + [ "possible_duplicate_source" ]).uniq)
          return self
        end
        if transaction_type == "转账"
          publish_transfer!(user)
        else
          publish_transaction!(user)
        end
        update!(status: "published")
      end
      self
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ResolutionError => error
      # Error classes/codes only: source text and amounts must not reach logs.
      DebugLogEntry.capture(category: "import", level: "warn", message: "iCost publication failed", source: "IcostRecord",
        family_id: family_id, metadata: { icost_record_id: id, error_class: error.class.name })
      reload
      issue = error.is_a?(ResolutionError) && error.message == "account_valuation_requires_review" ? error.message : "publication_validation_failed"
      update!(status: "needs_review", issues: (issues + [ issue ]).uniq) unless status == "published"
      self
    end

    def authorize!(user)
      IcostImport.authorize!(family, user)
      raise ResolutionError, "not_owner" unless icost_import.user_id == user.id
    end

    def writable_account!(user, id)
      account = family.accounts.writable_by(user).visible.manual.find(id)
      raise ResolutionError, "currency_mismatch" unless account.currency == currency
      account
    end

    def local_valuation_safe?(account)
      # Native balance materialization can fetch FX and security prices. A local
      # ledger import must stop before writing when those would be necessary.
      !account.entries.where.not(currency: account.currency).exists? &&
        !account.entries.where(entryable_type: "Trade").exists? && !account.holdings.exists?
    end

    def matching_account(user)
      if resolution["account_id"].present?
        return family.accounts.writable_by(user).visible.manual.find_by(id: resolution["account_id"], currency: currency)
      end
      names = [ account_name, "iCost预览｜#{account_name}｜#{currency}｜期初未知" ]
      accounts = family.accounts.writable_by(user).visible.manual.where(name: names, currency: currency).to_a
      accounts.one? ? accounts.first : nil
    end

    def legacy_entries(user)
      family.entries.where(account_id: family.accounts.writable_by(user).select(:id), entryable_type: "Transaction")
        .where("entries.notes LIKE ?", "%#{Entry.sanitize_sql_like(source_id)}%")
        .includes(:account, entryable: [ :category, :tags ]).to_a.select do |candidate|
          legacy_metadata(candidate)["source_id"] == source_id
        end
    end

    def legacy_metadata(candidate)
      json = candidate.notes.to_s.gsub("\r\n", "\n").split("[iCost原始字段与来源]\n", 2).last
      parsed = JSON.parse(json || "{}")
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def legacy_matches?(candidate)
      metadata = legacy_metadata(candidate)
      category = candidate.transaction.category
      path = category ? [ category.parent&.name, category.name ].compact : []
      metadata["row_sha256"] == row_sha256 && candidate.date == ledger_date &&
        candidate.amount == -amount && candidate.currency == currency &&
        candidate.account.currency == currency && candidate.account.name == "iCost预览｜#{account_name}｜#{currency}｜期初未知" &&
        path == category_path.reject(&:blank?) && (tags - candidate.transaction.tags.pluck(:name)).empty? &&
        candidate.transaction.kind == "standard" && !candidate.transaction.transfer? &&
        !IcostRecord.where(entry_id: candidate.id).exists?
    end

    def publish_transaction!(user)
      raise ResolutionError, "unsupported_type" unless %w[支出 收入].include?(transaction_type)
      account = resolution["account_id"].present? ? writable_account!(user, resolution["account_id"]) : matching_account(user)
      raise ResolutionError, "account_required" unless account
      raise ResolutionError, "account_valuation_requires_review" unless local_valuation_safe?(account)
      self.entry = account.entries.create!(date: ledger_date, amount: -amount, currency: currency,
        name: "iCost R#{source_row.to_s.rjust(4, '0')} · #{category_path.reject(&:blank?).last}",
        notes: note, idempotency_key: source_id, import_locked: true, user_modified: true,
        entryable: Transaction.new(kind: "standard", category: resolve_category!, tags: resolve_tags!,
          extra: { "icost" => { "source_id" => source_id, "explicit_type" => transaction_type } }))
      # Only local ledger materialization. Importing a local file must not trigger
      # enrichment, provider requests, inferred transfer matching or FX lookups.
      Balance::Materializer.new(account, strategy: :forward).materialize_balances
    end

    def publish_transfer!(user)
      raise ResolutionError, "review_required" unless resolution.values_at("from_account_id", "to_account_id").all?(&:present?)
      from = writable_account!(user, resolution["from_account_id"])
      to = writable_account!(user, resolution["to_account_id"])
      raise ResolutionError, "different_accounts_required" if from == to
      raise ResolutionError, "account_valuation_requires_review" unless [ from, to ].all? { |account| local_valuation_safe?(account) }
      # Use the native transfer rules for account types, but perform only local
      # balance materialization: a local file must not start provider requests.
      transfer = Transfer::Creator.new(family: family, source_account_id: from.id, destination_account_id: to.id,
        date: ledger_date, amount: amount.abs, tag_ids: resolve_tags!.map(&:id), idempotency_key: source_id).create(sync: false)
      self.entry = transfer.outflow_transaction.entry
      self.counterpart_entry = transfer.inflow_transaction.entry
      [ entry, counterpart_entry ].each { |leg| leg.update!(notes: note, import_locked: true) }
      [ from, to ].each { |account| Balance::Materializer.new(account, strategy: :forward).materialize_balances }
    end

    def resolve_category!
      parent = nil
      category_path.reject(&:blank?).each do |name|
        category = family.categories.find_by(name: name)
        raise ResolutionError, "category_hierarchy_conflict" if category && category.parent_id != parent&.id
        category ||= family.categories.create!(name: name, parent: parent, color: parent&.color || Category::COLORS.first,
          lucide_icon: Category.suggested_icon(name))
        parent = category
      end
      parent
    end

    def resolve_tags!
      names = tags + [ "iCost账本：#{book_name}" ].reject { |name| book_name.blank? }
      names.uniq.map { |name| family.tags.find_or_create_by!(name: name) { |tag| tag.color = Tag::COLORS.first } }
    end

    def same_family
      errors.add(:family, :invalid) unless icost_import&.family_id == family_id
      [ entry, counterpart_entry ].compact.each do |linked|
        errors.add(:entry, :invalid) unless linked.account.family_id == family_id
      end
    end
end
