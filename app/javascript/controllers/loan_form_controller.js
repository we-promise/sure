import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "installmentCost",
    "totalTerm",
    "currentTerm",
    "currentBalance",
    "originalBalance",
    "paymentPeriod",
    "paymentDay",
    "firstPaymentDate",
    "firstPaymentDateDisplay"
  ]

  connect() {
    this.calculateBalance()
    this.syncFirstPaymentDateDisplay()
  }

  syncFirstPaymentDateDisplay() {
    if (!this.hasFirstPaymentDateTarget || !this.hasFirstPaymentDateDisplayTarget) {
      return
    }

    if (this.firstPaymentDateTarget.value) {
      this.firstPaymentDateDisplayTarget.value = this.firstPaymentDateTarget.value
      return
    }

    this.calculateFirstPaymentDate()
  }

  calculateBalance() {
    // Real-time balance calculation as user types
    if (!this.hasInstallmentCostTarget || !this.hasTotalTermTarget || !this.hasCurrentTermTarget) {
      return
    }

    const rawCost = this.installmentCostTarget.value.trim()
    const rawTotalTerm = this.totalTermTarget.value.trim()
    const rawCurrentTerm = this.currentTermTarget.value.trim()

    if (!rawCost && !rawTotalTerm && !rawCurrentTerm) {
      this.clearCalculatedBalances()
      return
    }

    const costValue = rawCost.replace(/[^0-9.]/g, "")
    const cost = parseFloat(costValue) || 0
    const totalTerm = parseInt(rawTotalTerm) || 0
    const currentTerm = parseInt(rawCurrentTerm) || 0

    const originalBalance = cost * totalTerm
    const currentBalance = cost * (totalTerm - currentTerm)

    // Update calculated fields
    if (this.hasCurrentBalanceTarget) {
      this.currentBalanceTarget.value = currentBalance.toFixed(2)
    }
    if (this.hasOriginalBalanceTarget) {
      this.originalBalanceTarget.value = originalBalance.toFixed(2)
    }
  }

  clearCalculatedBalances() {
    if (this.hasCurrentBalanceTarget) {
      this.currentBalanceTarget.value = ""
    }
    if (this.hasOriginalBalanceTarget) {
      this.originalBalanceTarget.value = ""
    }
  }

  enforcePaymentDayLimit() {
    if (!this.hasPaymentDayTarget) {
      return
    }

    const original = this.paymentDayTarget.value
    const digitsOnly = original.replace(/\D/g, "")
    const limited = digitsOnly.slice(0, 2)

    if (limited !== original) {
      const selectionStart = this.paymentDayTarget.selectionStart
      const selectionEnd = this.paymentDayTarget.selectionEnd

      this.paymentDayTarget.value = limited

      if (selectionStart !== null && selectionEnd !== null) {
        const newPosition = Math.min(selectionStart, limited.length)
        this.paymentDayTarget.setSelectionRange(newPosition, newPosition)
      }
    }
  }

  calculateFirstPaymentDate() {
    // Calculate first payment date from payment day, current term, and payment period
    if (!this.hasPaymentDayTarget || !this.hasCurrentTermTarget || !this.hasPaymentPeriodTarget || !this.hasFirstPaymentDateTarget) {
      return
    }

    this.enforcePaymentDayLimit()

    const paymentDay = parseInt(this.paymentDayTarget.value) || 0
    const currentTerm = parseInt(this.currentTermTarget.value) || 0
    const paymentPeriod = this.paymentPeriodTarget.value

    // Only require valid payment day (1-31)
    if (paymentDay < 1 || paymentDay > 31) {
      this.firstPaymentDateTarget.value = ""
      if (this.hasFirstPaymentDateDisplayTarget) {
        this.firstPaymentDateDisplayTarget.value = ""
      }
      return
    }

    let firstPaymentDate

    if (currentTerm === 0) {
      // No payments made yet - first payment date is the NEXT occurrence of payment day
      firstPaymentDate = this.getNextOccurrenceOfDay(paymentDay)
    } else {
      // Payments have been made - calculate backwards from most recent payment
      const lastPaymentDate = this.getMostRecentPastDate(paymentDay)
      firstPaymentDate = this.subtractPeriods(lastPaymentDate, currentTerm - 1, paymentPeriod)
    }

    // Format as YYYY-MM-DD for date input
    const formattedDate = this.formatDate(firstPaymentDate)

    // Update hidden field (for form submission)
    this.firstPaymentDateTarget.value = formattedDate

    // Update display field (for user visibility)
    if (this.hasFirstPaymentDateDisplayTarget) {
      this.firstPaymentDateDisplayTarget.value = formattedDate
    }
  }

  // Get the most recent past occurrence of a given day of month
  // e.g., if today is Jan 14 and day is 15, returns Dec 15
  // e.g., if today is Jan 14 and day is 10, returns Jan 10
  getMostRecentPastDate(dayOfMonth) {
    const today = new Date()
    const currentDay = today.getDate()
    const currentMonth = today.getMonth()
    const currentYear = today.getFullYear()

    // If the day is today or in the past this month, use current month
    if (dayOfMonth <= currentDay) {
      // Handle edge case: day doesn't exist in current month (e.g., 31 in Feb)
      const lastDayOfMonth = new Date(currentYear, currentMonth + 1, 0).getDate()
      const adjustedDay = Math.min(dayOfMonth, lastDayOfMonth)
      return new Date(currentYear, currentMonth, adjustedDay)
    }

    // Otherwise, use previous month
    const prevMonth = currentMonth === 0 ? 11 : currentMonth - 1
    const prevYear = currentMonth === 0 ? currentYear - 1 : currentYear

    // Handle edge case: day doesn't exist in previous month (e.g., 31 in Feb)
    const lastDayOfPrevMonth = new Date(prevYear, prevMonth + 1, 0).getDate()
    const adjustedDay = Math.min(dayOfMonth, lastDayOfPrevMonth)

    return new Date(prevYear, prevMonth, adjustedDay)
  }

  // Get the next occurrence of a given day of month (for current_term = 0)
  // e.g., if today is Jan 14 and day is 15, returns Jan 15
  // e.g., if today is Jan 14 and day is 10, returns Feb 10
  getNextOccurrenceOfDay(dayOfMonth) {
    const today = new Date()
    const currentDay = today.getDate()
    const currentMonth = today.getMonth()
    const currentYear = today.getFullYear()

    // If the day is in the future this month, use current month
    if (dayOfMonth > currentDay) {
      const lastDayOfMonth = new Date(currentYear, currentMonth + 1, 0).getDate()
      const adjustedDay = Math.min(dayOfMonth, lastDayOfMonth)
      return new Date(currentYear, currentMonth, adjustedDay)
    }

    // Otherwise, use next month
    const nextMonth = currentMonth === 11 ? 0 : currentMonth + 1
    const nextYear = currentMonth === 11 ? currentYear + 1 : currentYear
    const lastDayOfNextMonth = new Date(nextYear, nextMonth + 1, 0).getDate()
    const adjustedDay = Math.min(dayOfMonth, lastDayOfNextMonth)

    return new Date(nextYear, nextMonth, adjustedDay)
  }

  subtractPeriods(date, periods, paymentPeriod) {
    const result = new Date(date)

    for (let i = 0; i < periods; i++) {
      switch (paymentPeriod) {
        case "weekly":
          result.setDate(result.getDate() - 7)
          break
        case "bi_weekly":
          result.setDate(result.getDate() - 14)
          break
        case "monthly":
          this.subtractMonths(result, 1)
          break
        case "quarterly":
          this.subtractMonths(result, 3)
          break
        case "yearly":
          this.subtractYears(result, 1)
          break
      }
    }

    return result
  }

  // Safely subtract months, handling end-of-month edge cases
  // e.g., Jan 31 - 1 month = Dec 31, Mar 31 - 1 month = Feb 28/29
  subtractMonths(date, months) {
    const originalDay = date.getDate()
    date.setMonth(date.getMonth() - months)

    // If the day changed, we overflowed (e.g., Jan 31 -> Mar 3 instead of Feb 28)
    // Set to last day of the target month
    if (date.getDate() !== originalDay) {
      date.setDate(0) // Sets to last day of previous month
    }
  }

  // Safely subtract years, handling leap year edge cases
  // e.g., Feb 29, 2024 - 1 year = Feb 28, 2023
  subtractYears(date, years) {
    const originalDay = date.getDate()
    const originalMonth = date.getMonth()
    date.setFullYear(date.getFullYear() - years)

    // Check if we landed on a different day (leap year overflow)
    if (date.getMonth() !== originalMonth || date.getDate() !== originalDay) {
      // Reset to the correct month and use last valid day
      date.setMonth(originalMonth + 1, 0) // Last day of originalMonth
    }
  }

  // Parse date string safely without timezone issues
  parseDate(dateStr) {
    const [year, month, day] = dateStr.split("-").map(Number)
    return new Date(year, month - 1, day)
  }

  formatDate(date) {
    const year = date.getFullYear()
    const month = String(date.getMonth() + 1).padStart(2, "0")
    const day = String(date.getDate()).padStart(2, "0")
    return `${year}-${month}-${day}`
  }
}
