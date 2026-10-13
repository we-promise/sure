# Deploying Sure on Pethost

[Pethost](https://pethost.dev) is a hosting platform that runs Docker Compose projects
with automatic HTTPS, persistent volumes, and nightly backups. It runs Sure's own
`compose.example.yml` with one command.

## Deploy

1. Install the [`pethost` CLI](https://pethost.dev/docs/cli/).

2. Download the sample Compose file into a folder of its own, as in the
   [Docker guide](docker.md):

   ```bash
   mkdir sure && cd sure
   curl --fail --location --silent --show-error --output compose.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.yml
   ```

3. Create a `.env` file beside it with your own secrets (`openssl rand -hex 64` generates
   the first):

   ```txt
   SECRET_KEY_BASE="replacemewiththegeneratedstring"
   POSTGRES_PASSWORD="replacemewithyourdesireddatabasepassword"
   ```

4. The app is served over HTTPS, so set this in `compose.yml`:

   ```txt
   RAILS_ASSUME_SSL: "true"
   ```

5. Deploy the folder:

   ```bash
   pethost deploy
   ```

   It starts the Rails web server, the Sidekiq worker, PostgreSQL, and Redis from the
   file as written, and prints the address, `https://sure.<your-domain>`.

6. Open the address and create your first account. To restrict future signups, see
   [Step 5a of the Docker guide](docker.md#step-5a-restrict-future-signups-optional).

The three volumes of the Compose file (`app-storage`, `postgres-data`, `redis-data`) are
kept across deploys and included in the nightly backups.

## Updating

Set the image tag in `compose.yml` to the new release, for both `web` and `worker`, and
run `pethost deploy` again. The address and the data stay.

A full walkthrough with each screen is in the
[Pethost guide for Sure](https://pethost.dev/blog/self-host-sure/).
