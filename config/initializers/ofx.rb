# frozen_string_literal: true

# Monkey-patch OFX gem to handle empty date fields gracefully.
# Some banks (e.g., ABN AMRO) export OFX files with empty <DTSTART/> tags,
# which causes the gem's build_date method to crash with "mon out of range".

module OFX
  module Parser
    class OFX102
      alias_method :original_build_date, :build_date

      def build_date(date)
        return nil if date.blank?

        original_build_date(date)
      end
    end
  end
end
