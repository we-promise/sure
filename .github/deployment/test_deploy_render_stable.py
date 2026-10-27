import contextlib
import io
import os
import unittest
from unittest.mock import patch

import deploy_render_stable as deploy


class DeploymentTest(unittest.TestCase):
    def setUp(self):
        self.env = {
            "RELEASE_TAG": "v0.9.0", "RENDER_API_KEY": "secret-token",
            "RENDER_APP_WEB_SERVICE_ID": "srv-web",
            "RENDER_APP_WORKER_SERVICE_ID": "srv-worker",
            "RENDER_APP_WEB_DEPLOY_HOOK_URL": "https://api.render.com/deploy/srv-web?key=web-secret",
            "RENDER_APP_WORKER_DEPLOY_HOOK_URL": "https://api.render.com/deploy/srv-worker?key=worker-secret",
            "RENDER_APP_URL": "https://example.com",
        }
        self.image = "ghcr.io/we-promise/sure:0.9.0"
        self.calls = []
        self.worker_fails = False
        self.web_fails = False
        self.bad_digest = False

    def api(self, path, token):
        self.assertEqual(token, "secret-token")
        self.calls.append(path)
        if "/deploys/" in path:
            is_worker = "srv-worker" in path
            return {"status": "update_failed" if (self.worker_fails and is_worker) or (self.web_fails and not is_worker) else "live",
                    "image": {"ref": self.image, "sha": "different" if self.bad_digest and is_worker else "sha256:abc"}}
        return {"type": "web_service" if path.endswith("srv-web") else "background_worker",
                "imagePath": "ghcr.io/we-promise/sure:stable"}

    def run_main(self):
        with patch.dict(os.environ, self.env, clear=True), patch.object(deploy, "api", side_effect=self.api), patch.object(deploy, "request", return_value=(200, b"ok")), patch.object(deploy, "trigger", side_effect=["dep-web", "dep-worker"]) as trigger, contextlib.redirect_stdout(io.StringIO()):
            deploy.main()
            return trigger

    def test_success_verifies_both_exact_deploys(self):
        trigger = self.run_main()
        self.assertEqual(trigger.call_count, 2)
        self.assertEqual(trigger.call_args_list[0].args[1], self.image)
        self.assertEqual(self.calls, ["services/srv-web", "services/srv-worker", "services/srv-web/deploys/dep-web", "services/srv-worker/deploys/dep-worker"])

    def test_non_stable_tags_never_trigger(self):
        for tag in ["main", "stable", "v0.9.0-alpha.1", "v0.9.0-beta.1", "v0.9.0-rc.1", "v0.9", "v01.2.3", "v1.2.3+meta"]:
            with self.subTest(tag=tag):
                self.env["RELEASE_TAG"] = tag
                with self.assertRaises(deploy.DeploymentError):
                    self.run_main()
        self.assertEqual(self.calls, [])

    def test_missing_configuration_fails_before_requests(self):
        del self.env["RENDER_API_KEY"]
        with self.assertRaisesRegex(deploy.DeploymentError, "RENDER_API_KEY"):
            self.run_main()
        self.assertEqual(self.calls, [])

    def test_wrong_worker_hook_fails_before_any_deploy(self):
        self.env["RENDER_APP_WORKER_DEPLOY_HOOK_URL"] = self.env["RENDER_APP_WEB_DEPLOY_HOOK_URL"]
        with patch.dict(os.environ, self.env, clear=True), patch.object(deploy, "api", side_effect=self.api), patch.object(deploy, "trigger") as trigger:
            with self.assertRaises(deploy.DeploymentError):
                deploy.main()
            trigger.assert_not_called()

    def test_web_smoke_failure_stops_before_worker_trigger(self):
        with patch.dict(os.environ, self.env, clear=True), patch.object(deploy, "api", side_effect=self.api), patch.object(deploy, "trigger", return_value="dep-web") as trigger, patch.object(deploy, "request", return_value=(503, b"unhealthy")), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(deploy.DeploymentError, "smoke check"):
                deploy.main()
            self.assertEqual(trigger.call_count, 1)

    def test_wrong_service_type_fails_before_trigger(self):
        with patch.dict(os.environ, self.env, clear=True), patch.object(deploy, "api", return_value={"type": "background_worker", "imagePath": "ghcr.io/we-promise/sure:stable"}), patch.object(deploy, "trigger") as trigger:
            with self.assertRaises(deploy.DeploymentError):
                deploy.main()
            trigger.assert_not_called()

    def test_previous_version_configuration_allows_next_release(self):
        original_api = self.api
        def previous_version(path, token):
            result = original_api(path, token)
            if "imagePath" in result:
                result["imagePath"] = "ghcr.io/we-promise/sure:0.8.0"
            return result
        self.api = previous_version
        self.assertEqual(self.run_main().call_count, 2)

    def test_hooks_cannot_send_secrets_to_other_hosts(self):
        for hook in ["http://api.render.com/deploy/srv-web?key=x", "https://evil.example/deploy/srv-web?key=x", "https://api.render.com@evil.example/deploy/srv-web?key=x", "https://api.render.com/deploy/srv-other?key=x", "https://api.render.com/deploy/srv-web?key=x&imgURL=wrong"]:
            with self.assertRaises(deploy.DeploymentError):
                deploy.validate_hook(hook, "srv-web")

    def test_web_failure_stops_before_worker(self):
        self.web_fails = True
        with self.assertRaises(deploy.DeploymentError):
            self.run_main()
        self.assertNotIn("services/srv-worker/deploys/dep-worker", self.calls)

    def test_worker_failure_does_not_report_success(self):
        self.worker_fails = True
        with self.assertRaises(deploy.DeploymentError):
            self.run_main()

    def test_different_digests_fail(self):
        self.bad_digest = True
        with self.assertRaisesRegex(deploy.DeploymentError, "digests differ"):
            self.run_main()

    def test_trigger_encodes_image_and_reads_id(self):
        with patch.object(deploy, "request", return_value=(200, b'{"deploy":{"id":"dep-new"}}')) as request:
            self.assertEqual(deploy.trigger(self.env["RENDER_APP_WEB_DEPLOY_HOOK_URL"], self.image), "dep-new")
            self.assertIn("imgURL=ghcr.io%2Fwe-promise%2Fsure%3A0.9.0", request.call_args.args[0])
            self.assertEqual(request.call_args.kwargs["method"], "POST")

    def test_queued_or_malformed_hook_response_fails(self):
        for result in [(202, b""), (200, b"{}"), (200, b"not json")]:
            with patch.object(deploy, "request", return_value=result), self.assertRaises(deploy.DeploymentError):
                deploy.trigger(self.env["RENDER_APP_WEB_DEPLOY_HOOK_URL"], self.image)

    def test_pending_then_live(self):
        with patch.object(deploy, "api", side_effect=[{"status": "update_in_progress"}, {"status": "live", "image": {"ref": self.image, "sha": "sha256:abc"}}]), patch.object(deploy.time, "sleep") as sleep:
            self.assertEqual(deploy.wait_live("srv-web", "dep-new", self.image, "token"), "sha256:abc")
            sleep.assert_called_once_with(10)

    def test_old_image_is_not_success(self):
        with patch.object(deploy, "api", return_value={"status": "live", "image": {"ref": "ghcr.io/we-promise/sure:old", "sha": "sha256:old"}}), self.assertRaises(deploy.DeploymentError):
            deploy.wait_live("srv-web", "dep-new", self.image, "token")

    def test_poll_timeout(self):
        with patch.object(deploy.time, "monotonic", side_effect=[0, 601]), self.assertRaisesRegex(deploy.DeploymentError, "Timed out"):
            deploy.wait_live("srv-web", "dep-new", self.image, "token")

    def test_request_errors_do_not_leak_url_or_token(self):
        with patch.object(deploy.urllib.request.OpenerDirector, "open", side_effect=deploy.urllib.error.URLError("web-secret secret-token")):
            with self.assertRaises(deploy.DeploymentError) as error:
                deploy.request(self.env["RENDER_APP_WEB_DEPLOY_HOOK_URL"], "secret-token")
            self.assertNotIn("secret", str(error.exception))

    def test_redirects_are_rejected(self):
        self.assertIsNone(deploy.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://evil.example"))


if __name__ == "__main__":
    unittest.main()
