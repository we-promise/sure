import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="admin-sso-form"
export default class extends Controller {
  static targets = ["callbackUrl", "testResult", "samlCallbackUrl"]

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

  copySamlCallback(event) {
    event.preventDefault()

    if (!this.hasSamlCallbackUrlTarget) return

    const callbackUrl = this.samlCallbackUrlTarget.textContent

    navigator.clipboard.writeText(callbackUrl).then(() => {
      const button = event.currentTarget
      const originalText = button.innerHTML
      button.innerHTML = '<svg class="w-4 h-4 inline" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path></svg> Copied!'
      button.classList.add('text-green-600')

      setTimeout(() => {
        button.innerHTML = originalText
        button.classList.remove('text-green-600')
      }, 2000)
    }).catch(err => {
      console.error('Failed to copy:', err)
      alert('Failed to copy to clipboard')
    })
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
          // Valid OIDC discovery endpoint
          issuerInput.classList.remove('border-yellow-300', 'border-red-300')
          issuerInput.classList.add('border-green-300')
          this.showValidationMessage(issuerInput, 'Valid OIDC issuer', 'success')
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
      this.showValidationMessage(issuerInput, "Could not validate from browser (CORS). Provider can still be saved.", 'warning')
    }
  }

  copyCallback(event) {
    event.preventDefault()

    const callbackDisplay = this.callbackUrlTarget
    if (!callbackDisplay) return

    const callbackUrl = callbackDisplay.textContent
    
    // Copy to clipboard
    navigator.clipboard.writeText(callbackUrl).then(() => {
      // Show success feedback
      const button = event.currentTarget
      const originalText = button.innerHTML
      button.innerHTML = '<svg class="w-4 h-4 inline" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path></svg> Copied!'
      button.classList.add('text-green-600')
      
      setTimeout(() => {
        button.innerHTML = originalText
        button.classList.remove('text-green-600')
      }, 2000)
    }).catch(err => {
      console.error('Failed to copy:', err)
      alert('Failed to copy to clipboard')
    })
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
    button.disabled = true
    button.textContent = 'Testing...'
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
      resultEl.textContent = `✗ Request failed: ${error.message}`
      resultEl.classList.add('text-red-600')
    } finally {
      button.disabled = false
      button.textContent = 'Test Connection'
    }
  }
}
