import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "pageInfo", "prevButton", "nextButton", "perPageSelect"]
  static values = {
    perPage: { type: Number, default: 20 },
    currentPage: { type: Number, default: 1 }
  }

  connect() {
    this.showPage()
  }

  get allItems() {
    return Array.from(this.listTarget.querySelectorAll(".filterable-item"))
  }

  get visibleItems() {
    return this.allItems.filter(item => item.style.display !== "none")
  }

  get totalPages() {
    return Math.max(1, Math.ceil(this.visibleItems.length / this.perPageValue))
  }

  showPage() {
    const visible = this.visibleItems
    const start = (this.currentPageValue - 1) * this.perPageValue
    const end = start + this.perPageValue

    visible.forEach((item, index) => {
      item.hidden = index < start || index >= end
    })

    this.updateControls()
  }

  rePage() {
    this.currentPageValue = 1
    this.showPage()
  }

  updateControls() {
    const total = this.visibleItems.length

    if (this.hasPrevButtonTarget) {
      this.prevButtonTarget.disabled = this.currentPageValue <= 1
    }
    if (this.hasNextButtonTarget) {
      this.nextButtonTarget.disabled = this.currentPageValue >= this.totalPages
    }
    if (this.hasPageInfoTarget) {
      if (total === 0) {
        this.pageInfoTarget.textContent = ""
      } else {
        const start = (this.currentPageValue - 1) * this.perPageValue + 1
        const end = Math.min(this.currentPageValue * this.perPageValue, total)
        this.pageInfoTarget.textContent = `${start}-${end} of ${total}`
      }
    }
    if (this.hasPerPageSelectTarget) {
      this.perPageSelectTarget.value = this.perPageValue
    }
  }

  nextPage() {
    if (this.currentPageValue < this.totalPages) {
      this.currentPageValue++
      this.showPage()
    }
  }

  prevPage() {
    if (this.currentPageValue > 1) {
      this.currentPageValue--
      this.showPage()
    }
  }

  changePerPage(event) {
    this.perPageValue = parseInt(event.target.value)
    this.currentPageValue = 1
    this.showPage()
  }
}
