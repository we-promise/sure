#!/usr/bin/env python3
"""Deploy a release image to Render and verify the exact deployments (stdlib only)."""
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request


class DeploymentError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(url, token=None, method="GET"):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    try:
        with urllib.request.build_opener(NoRedirect).open(
            urllib.request.Request(url, headers=headers, method=method), timeout=30
        ) as response:
            return response.status, response.read()
    except (urllib.error.URLError, TimeoutError, OSError):
        # URLs, API responses and exception messages can contain credentials.
        raise DeploymentError("Render/health HTTP request failed; inspect Render's dashboard.") from None


def api(path, token):
    status, body = request(f"https://api.render.com/v1/{path}", token)
    if status != 200:
        raise DeploymentError("Unexpected Render API response.")
    try:
        return json.loads(body)
    except ValueError:
        raise DeploymentError("Invalid Render API JSON response.") from None


def validate_hook(hook, service):
    url = urllib.parse.urlsplit(hook)
    query = urllib.parse.parse_qs(url.query)
    if (url.scheme != "https" or url.netloc != "api.render.com"
            or url.path != f"/deploy/{service}" or url.fragment
            or set(query) != {"key"} or len(query["key"]) != 1):
        raise DeploymentError("Deploy hook must be the unmodified Render hook for its configured service.")


def trigger(hook, image):
    # Do not retry triggers: an ambiguous network failure might have started a deploy.
    status, body = request(hook + "&" + urllib.parse.urlencode({"imgURL": image}), method="POST")
    if status == 202:
        raise DeploymentError("Render queued the deploy without an ID. Inspect Render before retrying; success cannot be verified.")
    if status != 200:
        raise DeploymentError("Unexpected deploy-hook response.")
    try:
        result = json.loads(body)
        deploy_id = result.get("deploy", result).get("id", "")
    except (ValueError, AttributeError):
        raise DeploymentError("Invalid deploy-hook response.") from None
    if not isinstance(deploy_id, str) or not re.fullmatch(r"dep-[a-zA-Z0-9]+", deploy_id):
        raise DeploymentError("Render did not return a deployment ID.")
    return deploy_id


def wait_live(service, deploy_id, image, token):
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        deploy = api(f"services/{service}/deploys/{deploy_id}", token)
        status = deploy.get("status")
        if status == "live":
            actual = deploy.get("image") or {}
            if actual.get("ref") != image or not actual.get("sha"):
                raise DeploymentError("Live deployment does not match the requested image.")
            print(f"{service}: {deploy_id} is live", flush=True)
            return actual["sha"]
        if status not in {"created", "build_in_progress", "pre_deploy_in_progress", "update_in_progress", "queued"}:
            raise DeploymentError(f"Deployment {deploy_id} failed or entered an unexpected state.")
        time.sleep(10)
    raise DeploymentError(f"Timed out waiting for {deploy_id}; inspect Render before retrying.")


def main():
    names = ["RELEASE_TAG", "RENDER_API_KEY", "RENDER_WEB_DEPLOY_HOOK_URL",
             "RENDER_WORKER_DEPLOY_HOOK_URL", "RENDER_RELEASE_CHANNEL", "RENDER_URL"]
    missing = [name for name in names if not os.environ.get(name)]
    if missing:
        raise DeploymentError("Missing configuration: " + ", ".join(missing))
    tag = os.environ["RELEASE_TAG"]
    channel = os.environ["RENDER_RELEASE_CHANNEL"]
    version = r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    pattern = version if channel == "stable" else version + r"-alpha\.(0|[1-9][0-9]*)"
    if channel not in {"stable", "alpha"} or not re.fullmatch(pattern, tag):
        raise DeploymentError("Release tag must match the environment's stable or alpha channel.")
    token = os.environ["RENDER_API_KEY"]
    image = f"ghcr.io/we-promise/sure:{tag[1:]}"
    base_url = os.environ["RENDER_URL"].rstrip("/")
    url = urllib.parse.urlsplit(base_url)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment or url.path:
        raise DeploymentError("RENDER_URL must be an HTTPS origin.")
    services = []
    # Validate both targets and API access before triggering either deployment.
    for kind, expected_type in [("WEB", "web_service"), ("WORKER", "background_worker")]:
        hook = os.environ[f"RENDER_{kind}_DEPLOY_HOOK_URL"]
        service = urllib.parse.urlsplit(hook).path.removeprefix("/deploy/")
        if not re.fullmatch(r"srv-[a-zA-Z0-9]+", service):
            raise DeploymentError("Invalid Render service ID in hook.")
        validate_hook(hook, service)
        current = api(f"services/{service}", token)
        if current.get("type") != expected_type or not re.fullmatch(r"ghcr\.io/we-promise/sure:[A-Za-z0-9_.-]+", current.get("imagePath", "")):
            raise DeploymentError("Target must be the expected Sure image-backed service.")
        services.append((service, hook))
    digests = []
    for index, (service, hook) in enumerate(services):
        deploy_id = trigger(hook, image)
        print(f"{service}: started {deploy_id}", flush=True)
        digests.append(wait_live(service, deploy_id, image, token))
        if index == 0:
            for path in ["/up", "/sessions/new"]:
                status, _ = request(base_url + path)
                if status != 200:
                    raise DeploymentError("Web smoke check failed; worker has not been deployed.")
    if digests[0] != digests[1]:
        raise DeploymentError("Web and worker image digests differ; inspect Render.")
    print(f"Web and worker verified live on {image} ({digests[0]}).", flush=True)


if __name__ == "__main__":
    try:
        main()
    except DeploymentError as error:
        print(f"::error::{error}", flush=True)
        raise SystemExit(1)
