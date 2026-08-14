# The worker and the migration runner, as one image.
#
#   docker build -f infra/docker/worker.Dockerfile -t bel-worker .
#
# **Two entry points, one image, on purpose.** The migration runner and the
# worker share the whole dependency graph and differ by one `bin/` file; two
# images would be two builds, two tags and two chances for the schema step and
# the process that reads it to be from different commits — which is the one
# way a migration can go wrong that nobody notices until the pass runs.
#
#   /app/bin/worker    one pass, then exit (a KEDA ScaledJob, ADR-0021)
#   /app/bin/migrate   applies what the database has not seen, then exits
#
# The migration runner is the image's default: it is what a deployment runs
# first, and a Job that forgets to name a command should do the harmless thing.
FROM dart:stable AS build

WORKDIR /app

# The same trimmed workspace the API image builds, and for the same reason —
# see `api.Dockerfile`, which explains what the `sed` is buying.
COPY pubspec.yaml pubspec.lock ./
COPY packages/bel_domain packages/bel_domain
COPY packages/bel_contracts packages/bel_contracts
COPY packages/bel_crypto packages/bel_crypto
COPY packages/bel_localization packages/bel_localization
COPY services/api services/api
COPY services/worker services/worker
COPY config config
COPY infra/migrations infra/migrations

RUN sed -i -e '\#^  - apps/#d' \
           -e '\#^  - packages/bel_design$#d' \
           -e '\#^  - packages/bel_backoffice$#d' \
           -e '\#^  - packages/bel_secure_store$#d' \
           -e '\#^  - packages/bel_client$#d' pubspec.yaml \
 && dart pub get

RUN dart compile exe services/worker/bin/worker.dart -o /app/worker \
 && dart compile exe services/worker/bin/migrate.dart -o /app/migrate

FROM scratch

COPY --from=build /runtime/ /
COPY --from=build /app/worker /app/bin/worker
COPY --from=build /app/migrate /app/bin/migrate
COPY --from=build /app/packages/bel_localization/i18n /app/i18n
COPY --from=build /app/config /app/config
# The migration runner reads the files rather than compiling them in, because
# a schema step whose SQL is invisible is a schema step nobody can review.
COPY --from=build /app/infra/migrations /app/migrations

ENV BEL_I18N_DIR=/app/i18n
ENV BEL_MARKETS_FILE=/app/config/markets.yaml
ENV MIGRATIONS_DIR=/app/migrations
ENV BEL_ENV_FILE=none

ENTRYPOINT ["/app/bin/migrate"]
