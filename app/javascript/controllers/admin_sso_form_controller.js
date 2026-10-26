import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="admin-sso-form"
export default class extends Controller {
  static targets = ["callbackUrl", "testResult", "samlCallbackUrl"]
  static values = { labels: Object }

  connect() {
    // Initialize field visibility on page load
    this.toggleFields()
    // Initialize callback URL
    this.updateCallbackUrl()
  }

  updateCallbackUrl() {
    const nameInput = this.element.querySelector('input[name*="[name]"]')
    const callbackDisplay = this.callbackUrlTarget

    if (!nameInput || !callbackDisplay) return

    const providerName = nameInput.value.trim() || 'PROVIDER_NAME'
    const baseUrl = window.location.origin
    callbackDisplay.textContent = `${baseUrl}/auth/${providerName}/callback`
  }

  toggleFields() {
    const strategySelect = this.element.querySelector('select[name*="[strategy]"]')
    if (!strategySelect) return

    const strategy = strategySelect.value
    const isOidc = strategy === "openid_connect"
    const isSaml = strategy === "saml"

    // Toggle OIDC fields
    const oidcFields = this.element.querySelectorAll('[data-oidc-field]')
    oidcFields.forEach(field => {
      if (isOidc) {
        field.classList.remove('hidden')
      } else {
        field.classList.add('hidden')
      }
    })

    // Toggle SAML fields
    const samlFields = this.element.querySelectorAll('[data-saml-field]')
    samlFields.forEach(field => {
      if (isSaml) {
        field.classList.remove('hidden')
      } else {
        field.classList.add('hidden')
      }
    })

    // Update SAML callback URL if present
    if (this.hasSamlCallbackUrlTarget) {
      this.updateSamlCallbackUrl()
    }
  }

  updateSamlCallbackUrl() {
    const nameInput = this.element.querySelector('input[name*="[name]"]')
    if (!nameInput || !this.hasSamlCallbackUrlTarget) return

    const providerName = nameInput.value.trim() || 'PROVIDER_NAME'
    const baseUrl = window.location.origin
    this.samlCallbackUrlTarget.textContent = `${baseUrl}/auth/${providerName}/callback`
  }

  async validateIssuer(event) {
    const issuerInput = event.target
    const issuer = issuerInput.value.trim()
    
    if (!issuer) return

    try {
      // Construct discovery URL
      const discoveryUrl = issuer.endsWith('/') 
        ? `${issuer}.well-known/openid-configuration`
        : `${issuer}/.well-known/openid-configuration`

      // Show loading state
      issuerInput.classList.add('border-yellow-300')
      
      const response = await fetch(discoveryUrl, {
        method: 'GET',
        headers: { 'Accept': 'application/json' }
      })

      if (response.ok) {
        const data = await response.json()
        if (data.issuer) {
          if (data.issuer === issuer) {
            issuerInput.classList.remove('border-yellow-300', 'border-red-300', 'border-amber-300')
            issuerInput.classList.add('border-green-300')
            this.showValidationMessage(issuerInput, this.labelsValue.valid_issuer, 'success')
          } else {
            issuerInput.classList.remove('border-yellow-300', 'border-green-300')
            issuerInput.classList.add('border-amber-300')

            const trailingSlashOnly = data.issuer.replace(/\/$/, '') === issuer.replace(/\/$/, '')
            const template = trailingSlashOnly
              ? this.labelsValue.issuer_slash_mismatch
              : this.labelsValue.issuer_mismatch
            const message = template.replace("%{issuer}", () => data.issuer)

            this.showValidationMessage(issuerInput, message, 'warning')
          }
        } else {
          throw new Error('Invalid discovery response')
        }
      } else {
        throw new Error(`Discovery endpoint returned ${response.status}`)
      }
    } catch (error) {
      // CORS errors are expected when validating from browser - show as warning not error
      issuerInput.classList.remove('border-yellow-300', 'border-green-300')
      issuerInput.classList.add('border-amber-300')
      this.showValidationMessage(issuerInput, this.labelsValue.browser_validation_failed, 'warning')
    }
  }

  showValidationMessage(input, message, type) {
    // Remove any existing validation message
    const existingMessage = input.parentElement.querySelector('.validation-message')
    if (existingMessage) {
      existingMessage.remove()
    }

    // Create new validation message
    const messageEl = document.createElement('p')
    const colorClass = type === 'success' ? 'text-green-600' : type === 'warning' ? 'text-amber-600' : 'text-red-600'
    messageEl.className = `validation-message mt-1 text-sm ${colorClass}`
    messageEl.textContent = message

    input.parentElement.appendChild(messageEl)

    // Auto-remove after 5 seconds (except warnings which stay)
    if (type !== 'warning') {
      setTimeout(() => {
        messageEl.remove()
        input.classList.remove('border-green-300', 'border-red-300', 'border-amber-300')
      }, 5000)
    }
  }

  async testConnection(event) {
    const button = event.currentTarget
    const testUrl = button.dataset.adminSsoFormTestUrlValue
    const resultEl = this.testResultTarget

    if (!testUrl) return

    // Show loading state
    const originalMarkup = button.innerHTML
    button.disabled = true
    button.textContent = this.labelsValue.testing
    resultEl.textContent = ''
    resultEl.className = 'ml-2 text-sm'

    try {
      const response = await fetch(testUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
        }
      })

      const data = await response.json()

      if (data.success) {
        resultEl.textContent = `✓ ${data.message}`
        resultEl.classList.add('text-green-600')
      } else {
        resultEl.textContent = `✗ ${data.message}`
        resultEl.classList.add('text-red-600')
      }

      // Show details in console for debugging
      if (data.details && Object.keys(data.details).length > 0) {
        console.log('SSO Test Connection Details:', data.details)
      }
    } catch (error) {
      resultEl.textContent = `✗ ${this.labelsValue.request_failed.replace("%{error}", () => error.message)}`
      resultEl.classList.add('text-red-600')
    } finally {
      button.disabled = false
      button.innerHTML = originalMarkup
    }
  }
}
