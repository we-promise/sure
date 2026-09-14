import { Controller } from "@hotwired/stimulus";
import {
  capturePreviewEvent,
  feedbackClient,
  initializeSelfHostedFeedback,
  sankeyFeedbackResponse,
  sankeyFeedbackSurvey,
} from "utils/sankey_preview_analytics";

export default class extends Controller {
  static targets = [
    "display",
    "expandButton",
    "expandedDialog",
    "feedbackDialog",
    "status",
    "form",
  ];
  static values = {
    surveyId: String,
    selfHosted: Boolean,
    feedbackKey: String,
    feedbackHost: String,
  };

  connect() {
    if (this.selfHostedValue) {
      initializeSelfHostedFeedback(
        window.posthog,
        this.feedbackKeyValue,
        this.feedbackHostValue,
        () => document.dispatchEvent(new Event("posthog:ready")),
      );
    }
    this.displays = new Set();
    this.state = "loading";
    this.active = true;
    this.observer = new IntersectionObserver(([entry]) => {
      this.visible = entry.isIntersecting;
      this.trackDisplay();
    });
    this.observer.observe(this.displayTarget);
  }

  get posthog() {
    if (this.selfHostedValue && !this.feedbackKeyValue) return undefined;
    return feedbackClient(window.posthog, this.selfHostedValue);
  }

  disconnect() {
    this.clear();
    this.observer?.disconnect();
  }

  clear() {
    this.dismiss();
    this.active = false;
    this.feedbackRequest = null;
    clearTimeout(this.feedbackTimeout);
    this.expandedDialogTarget.close();
    this.restoreDrag();
    this.feedbackDialogTarget.close();
    this.formTarget.reset();
    this.survey = null;
  }

  update({ detail }) {
    if (detail.state === "loading") this.displays.clear();
    this.state = detail.state;
    this.expandButtonTarget.disabled = !detail.ready;
    this.trackDisplay();
  }

  trackDisplay() {
    if (
      !this.active ||
      document.hidden ||
      !this.visible ||
      this.state === "loading" ||
      !this.displayTarget.getClientRects().length
    )
      return;
    // Count each rendered result once. Scrolling and resize callbacks aren't
    // additional displays; a date-range navigation creates a new controller.
    const key = `inline:${this.state}`;
    if (this.displays.has(key)) return;
    if (
      capturePreviewEvent(this.posthog, "sankey_preview_displayed", {
        surface: "inline",
        state: this.state,
      })
    ) {
      this.displays.add(key);
    }
  }

  expand() {
    if (this.state !== "content" || this.expandedDialogTarget.open) return;
    this.section = this.element.closest(
      "[data-dashboard-sortable-target='section']",
    );
    this.originalDraggable = this.section?.getAttribute("draggable");
    this.section?.setAttribute("draggable", "false");
    this.expandedDialogTarget.showModal();
    capturePreviewEvent(this.posthog, "sankey_preview_displayed", {
      surface: "expanded",
      state: this.state,
    });
  }

  restoreDrag() {
    if (!this.section) return;
    if (this.originalDraggable === null)
      this.section.removeAttribute("draggable");
    else this.section.setAttribute("draggable", this.originalDraggable);
    this.section = null;
  }

  stopKeydown(event) {
    // The enclosing dashboard section also handles Enter/Space for reordering.
    event.stopPropagation();
  }

  feedback({ params: { rating } }) {
    if (!["positive", "negative"].includes(rating)) return;
    this.rating = rating;
    this.survey = null;
    this.sent = false;
    this.formTarget.reset();
    this.formTarget.hidden = true;
    this.statusTarget.textContent = this.statusTarget.dataset.loading;
    this.feedbackDialogTarget.showModal();
    const posthog = this.posthog;
    if (
      !this.hasSurveyIdValue ||
      !this.surveyIdValue ||
      !posthog?.__loaded ||
      posthog.has_opted_out_capturing?.()
    ) {
      this.unavailable();
      return;
    }
    capturePreviewEvent(posthog, "sankey_preview_feedback_clicked", {
      rating,
      state: this.state,
    });
    const request = {};
    this.feedbackRequest = request;
    this.feedbackTimeout = setTimeout(() => {
      if (this.feedbackRequest === request) this.unavailable();
    }, 5000);
    try {
      posthog.getSurveys((surveys) => {
        if (
          !this.active ||
          this.feedbackRequest !== request ||
          !this.feedbackDialogTarget.open
        )
          return;
        clearTimeout(this.feedbackTimeout);
        this.survey = sankeyFeedbackSurvey(surveys, this.surveyIdValue);
        if (!this.survey) return this.unavailable();
        this.statusTarget.textContent = "";
        this.formTarget.querySelector("[data-feedback-question]").textContent =
          this.survey.feedback.question;
        const input = this.formTarget.elements.feedback;
        input.required = !this.survey.feedback.optional;
        this.formTarget.hidden = false;
        capturePreviewEvent(posthog, "survey shown", {
          $survey_id: this.survey.id,
        });
        input.focus();
      });
    } catch {
      this.unavailable();
    }
  }

  unavailable() {
    this.feedbackRequest = null;
    clearTimeout(this.feedbackTimeout);
    this.formTarget.hidden = true;
    this.statusTarget.textContent = this.statusTarget.dataset.unavailable;
  }

  submit(event) {
    event.preventDefault();
    if (!this.survey || this.sent) return;
    const feedback = this.formTarget.elements.feedback.value.trim();
    if (!feedback && !this.survey.feedback.optional) {
      this.formTarget.elements.feedback.value = "";
      this.formTarget.reportValidity();
      return;
    }
    if (
      !capturePreviewEvent(
        this.posthog,
        "survey sent",
        sankeyFeedbackResponse(this.survey, this.rating, feedback),
      )
    ) {
      this.unavailable();
      return;
    }
    this.sent = true;
    this.formTarget.reset();
    this.formTarget.hidden = true;
    this.statusTarget.textContent = this.statusTarget.dataset.thanks;
  }

  dismiss() {
    this.feedbackRequest = null;
    clearTimeout(this.feedbackTimeout);
    if (this.survey && !this.sent)
      capturePreviewEvent(this.posthog, "survey dismissed", {
        $survey_id: this.survey.id,
      });
    this.survey = null;
    this.formTarget.reset();
  }
}
