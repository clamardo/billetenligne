# The API, as an image.
#
# Build from the repository root, because the server is four path packages and
# a route tree and none of them resolve from `services/api` alone:
#
#   docker build -f infra/docker/api.Dockerfile -t bel-api .
#
# **Compiled, not interpreted.** `dart compile exe` gives a cold start in
# milliseconds and an image with no SDK in it — which matters twice over here:
# the pods are small, and the smaller surface is one fewer thing to patch on a
# server that holds a ticket signing key.
FROM dart:stable AS build

WORKDIR /app

# Only what the server needs. The workspace root lists four Flutter apps and
# three Flutter packages as members, and `dart pub get` will not resolve a
# workspace whose members are missing from disk — so the members come out of
# the file here rather than the Flutter SDK coming into the image, which would
# be a gigabyte and several minutes to build a server that never touches it.
#
# The cost is honest and worth naming: this resolves the server's dependencies
# rather than replaying the committed lockfile, so an image can pick up a patch
# release CI has not seen. `tool/images.sh --check` is what catches that.
COPY pubspec.yaml pubspec.lock ./
COPY packages/bel_domain packages/bel_domain
COPY packages/bel_contracts packages/bel_contracts
COPY packages/bel_crypto packages/bel_crypto
COPY packages/bel_localization packages/bel_localization
COPY services/api services/api
COPY config config

RUN sed -i -e '\#^  - apps/#d' \
           -e '\#^  - packages/bel_design$#d' \
           -e '\#^  - packages/bel_backoffice$#d' \
           -e '\#^  - packages/bel_secure_store$#d' \
           -e '\#^  - packages/bel_client$#d' \
           -e '\#^  - services/worker$#d' pubspec.yaml \
 && dart pub get

# `dart_frog build` generates `build/bin/server.dart` from the route tree. The
# generated project keeps `resolution: workspace`, so it is compiled from
# `services/api` — that is the directory whose package config resolves it.
RUN dart pub global activate dart_frog_cli
WORKDIR /app/services/api
RUN rm -rf build \
 && /root/.pub-cache/bin/dart_frog build \
 && dart compile exe build/bin/server.dart -o /app/server

# Two directories of data the server reads at runtime rather than compiles in:
# the translation catalog (one catalog for the clients and the server,
# ADR-0008) and the market file, which decides which payment rails this
# deployment announces and is the one file a market switch touches.
FROM scratch

COPY --from=build /runtime/ /
COPY --from=build /app/server /app/bin/server
COPY --from=build /app/packages/bel_localization/i18n /app/i18n
COPY --from=build /app/config /app/config

ENV BEL_I18N_DIR=/app/i18n
ENV BEL_MARKETS_FILE=/app/config/markets.yaml
# There is no `infra/dev` in this image, so the local-environment fallback has
# nothing to find — said explicitly anyway, because a deployment that silently
# reads a file somebody baked in by accident is the failure that fallback was
# written to prevent.
ENV BEL_ENV_FILE=none
ENV PORT=8080

EXPOSE 8080
ENTRYPOINT ["/app/bin/server"]
