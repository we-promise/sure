module Entryable
  extend ActiveSupport::Concern

  TYPES = %w[Valuation Transaction Trade]

  def self.from_type(entryable_type)
    entryable_type.presence_in(TYPES).constantize
  end

  # A vest's trade columns and its parts' labels, which Trade::VestForm
  # writes with the vest (Entry#vest_write).
  VEST_ATTRIBUTES = %w[qty price units_withheld investment_activity_label kind].freeze

  included do
    include Enrichable

    # Checked here as well as on the entry, because a rule or a provider
    # saves the transaction or trade without it.
    validate :vest_attributes_written_together, on: :update

    has_one :entry, as: :entryable, touch: true, dependent: :destroy

    scope :with_entry, -> { joins(:entry) }

    scope :visible, -> { with_entry.merge(Entry.visible) }

    scope :in_period, ->(period) {
      with_entry.where(entries: { date: period.start_date..period.end_date })
    }

    scope :reverse_chronological, -> {
      with_entry.merge(Entry.reverse_chronological)
    }

    scope :chronological, -> {
      with_entry.merge(Entry.chronological)
    }
  end

  private
    # Also refuses turning an entry into a vest, or a vest into something else.
    # A vest is only ever trades and transactions; a valuation's kind is its own.
    def vest_attributes_written_together
      return unless is_a?(Transaction) || is_a?(Trade)

      changed_attributes = changed & VEST_ATTRIBUTES
      return if changed_attributes.empty? || entry.nil? || entry.vest_write

      labels = [ investment_activity_label_was, investment_activity_label ]
      return unless entry.vest_entry_id_was.present? || labels.include?(Trade::VEST_LABEL)

      changed_attributes.each { |attribute| errors.add(attribute, "changes only with its vest, on the vest's own screen") }
    end
end
