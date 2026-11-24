# frozen_string_literal: true

module Family::RevolutXConnectable
  extend ActiveSupport::Concern

  included do
    has_many :revolut_x_items, dependent: :destroy
  end

  def can_connect_revolut_x?
    true
  end

  def has_revolut_x_credentials?
    revolut_x_items.active.any?(&:credentials_configured?)
  end
end
