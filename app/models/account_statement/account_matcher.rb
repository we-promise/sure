# frozen_string_literal: true

class AccountStatement::AccountMatcher
  Match = Struct.new(:account, :confidence, keyword_init: true)

  attr_reader :statement

  def initialize(statement)
    @statement = statement
  end

  def best_match
    candidates = statement.family.accounts.visible.to_a.filter_map do |account|
      confidence = confidence_for(account)
      next if confidence < 0.35

      Match.new(account: account, confidence: confidence.round(4))
    end

    candidates.max_by(&:confidence)
  end

  private

    def confidence_for(account)
      score = 0.to_d

      if institution_hint.present?
        score += 0.45.to_d if account_text(account).include?(institution_hint)
      end

      if account_name_hint.present?
        score += 0.25.to_d if account.name.to_s.downcase.include?(account_name_hint)
      end

      if account_last4_hint.present?
        score += 0.25.to_d if account_sensitive_match_text(account).include?(account_last4_hint)
      end

      score += 0.05.to_d if statement.statement_currency == account.currency
      [ score, 1.to_d ].min
    end

    def institution_hint
      @institution_hint ||= statement.institution_name_hint.to_s.downcase.squish.presence
    end

    def account_name_hint
      @account_name_hint ||= statement.account_name_hint.to_s.downcase.squish.presence
    end

    def account_last4_hint
      @account_last4_hint ||= statement.account_last4_hint.to_s.downcase.squish.presence
    end

    def account_text(account)
      [
        account.name,
        account.institution_name,
        account.institution_domain
      ].compact.join(" ").downcase
    end

    def account_sensitive_match_text(account)
      # Exclude user-controlled account notes from matching hints. Statement
      # matching should use conservative account metadata, not free-form prose
      # that can accidentally manufacture a last-four match.
      [
        account.name,
        account.institution_name
      ].compact.join(" ").downcase
    end
end
