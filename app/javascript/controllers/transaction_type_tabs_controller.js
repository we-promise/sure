import { Controller } from "@hotwired/stimulus"

const ACTIVE_CLASSES = ["bg-container", "text-primary", "shadow-sm"]
const INACTIVE_CLASSES = ["hover:bg-container", "text-subdued", "hover:text-primary", "hover:shadow-sm"]

export default class extends Controller {
  static targets = ["tab", "natureField"]

  selectTab(event) {
    event.preventDefault()

    const selectedTab = event.currentTarget
    this.natureFieldTarget.value = selectedTab.dataset.nature

    this.tabTargets.forEach(tab => {
      const isActive = tab === selectedTab
      tab.classList.remove(...(isActive ? INACTIVE_CLASSES : ACTIVE_CLASSES))
      tab.classList.add(...(isActive ? ACTIVE_CLASSES : INACTIVE_CLASSES))
    })
  }
}
