# frozen_string_literal: true

class BankSyncStatusComponent < ViewComponent::Base
  attr_reader :presenter

  def initialize(presenter:)
    @presenter = presenter
  end
end
