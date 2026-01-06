class InstallmentService
  def self.generate_entries
    new.generate_entries
  end

  def generate_entries
    Installment.where(auto_generate: true).find_each do |installment|
      process_installment(installment)
    end
  end

  private

    def process_installment(installment)
      return unless installment.account.present?

      total = installment.total_installments

      total.times do |i|
        occurrence_index = i + 1
        due_date = calculate_due_date(installment, i)

        # Don't generate future transactions
        break if due_date > Date.current

        expected_name = "Installment: #{installment.name} (#{occurrence_index} of #{total})"

        # Check if transaction already exists for this specific installment occurrence
        # We match strictly on the name format to avoid duplicating
        already_exists = installment.transactions
                                    .joins(:entry)
                                    .exists?(entries: { name: expected_name })

        unless already_exists
          create_transaction(installment, due_date, expected_name)
        end
      end
    end

    def calculate_due_date(installment, period_offset)
      case installment.payment_period
      when "weekly"
        installment.first_payment_date + period_offset.weeks
      when "monthly"
        installment.first_payment_date + period_offset.months
      when "quarterly"
        installment.first_payment_date + period_offset.quarters
      when "yearly"
        installment.first_payment_date + period_offset.years
      else
        installment.first_payment_date
      end
    end

    def create_transaction(installment, date, name)
      # Amount is negative because it is a payment (reducing the liability or money out)
      amount = -installment.installment_cost.amount

      Entry.create!(
        account: installment.account,
        date: date,
        amount: amount,
        currency: installment.currency,
        name: name,
        entryable: Transaction.new(
          installment: installment,
          kind: "loan_payment"
        )
      )
    end
end
