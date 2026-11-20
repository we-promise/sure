# Deploying Sure on PikaPods

[PikaPods](https://www.pikapods.com) is a managed hosting service for open-source apps.
It runs Sure with PostgreSQL, Redis, and the Sidekiq worker, and handles HTTPS and app
updates. Everything is set up from the web dashboard, with no server or Docker
commands.

[![Run on PikaPods](https://www.pikapods.com/static/run-button.svg)](https://www.pikapods.com/pods?run=sure)

## Getting started

1. Click **Run on PikaPods** above, then sign in or create a PikaPods account.
2. Choose a name and a hosting region for the pod.
3. Review the CPU, memory, and storage, and the estimated monthly cost. Sure needs at
   least 1 GB of memory. You can change the resources later in the pod's settings.
4. Create the pod. When it is running, open its address.
5. Choose **Create your account** on the login page. The first account is an
   administrator. To restrict future signups, see
   [Step 5a of the Docker guide](docker.md#step-5a-restrict-future-signups-optional).

The PikaPods [getting started guide](https://help.pikapods.com/manage/getting-started)
covers creating and managing a pod, including using your own domain.

## Updates

PikaPods updates Sure for you. New releases are tested before they reach your pod and
roll out weekly, including database migrations.

## Data and backups

Your data lives on the pod. You can download its files and database with the file
access in the pod's settings, or set up automatic backups to your own S3-compatible
storage. See the PikaPods [backup guide](https://help.pikapods.com/manage/backup) for
setup and restore.

## Getting help

- Hosting, billing, or pod issues: the [PikaPods help pages](https://help.pikapods.com/).
- Sure features or bugs: [GitHub Issues](https://github.com/we-promise/sure/issues).

Part of the hosting revenue from Sure pods goes to the Sure project.
