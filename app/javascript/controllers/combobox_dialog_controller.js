import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="combobox-dialog"
export default class extends Controller {
  connect() {
    // Check if we're inside a dialog
    this.isInDialog = this.element.closest('dialog') !== null;

    if (this.isInDialog) {
      this.observeListbox();
      this.setupEventListeners();
    }
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect();
    }
    if (this.scrollHandler) {
      window.removeEventListener('scroll', this.scrollHandler, { capture: true });
    }
    if (this.resizeHandler) {
      window.removeEventListener('resize', this.resizeHandler);
    }
  }

  setupEventListeners() {
    // Reposition on scroll/resize
    this.scrollHandler = () => {
      const listbox = this.element.querySelector('.hw-combobox__listbox');
      if (listbox && this.isVisible(listbox)) {
        this.positionListbox(listbox);
      }
    };

    this.resizeHandler = () => {
      const listbox = this.element.querySelector('.hw-combobox__listbox');
      if (listbox && this.isVisible(listbox)) {
        this.positionListbox(listbox);
      }
    };

    window.addEventListener('scroll', this.scrollHandler, { passive: true, capture: true });
    window.addEventListener('resize', this.resizeHandler, { passive: true });
  }

  observeListbox() {
    // Use MutationObserver to watch for listbox showing/hiding
    this.observer = new MutationObserver(() => {
      const listbox = this.element.querySelector('.hw-combobox__listbox');
      if (listbox && this.isVisible(listbox)) {
        // Small delay to ensure DOM is updated
        setTimeout(() => this.positionListbox(listbox), 10);
      }
    });

    this.observer.observe(this.element, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['style', 'hidden', 'class']
    });
  }

  isVisible(element) {
    return element &&
           !element.hidden &&
           element.style.display !== 'none' &&
           element.offsetParent !== null;
  }

  positionListbox(listbox) {
    if (!this.isInDialog) return;

    const inputWrapper = this.element.querySelector('.hw-combobox__main__wrapper') ||
                        this.element.querySelector('input');
    if (!inputWrapper) return;

    const rect = inputWrapper.getBoundingClientRect();
    const viewportHeight = window.innerHeight;
    const viewportWidth = window.innerWidth;

    // Calculate available space below and above
    const spaceBelow = viewportHeight - rect.bottom - 16;
    const spaceAbove = rect.top - 16;

    // Position listbox
    const maxHeight = Math.min(200, Math.max(spaceBelow, spaceAbove));

    // Apply styles
    Object.assign(listbox.style, {
      position: 'fixed',
      left: `${Math.max(8, Math.min(rect.left, viewportWidth - rect.width - 8))}px`,
      width: `${Math.min(rect.width, viewportWidth - 16)}px`,
      maxHeight: `${maxHeight}px`,
    });

    // Check if we should position above or below
    if (spaceBelow >= 150 || spaceBelow >= spaceAbove) {
      // Position below
      listbox.style.top = `${rect.bottom + 8}px`;
    } else {
      // Position above
      listbox.style.top = `${rect.top - maxHeight - 8}px`;
    }
  }
}
