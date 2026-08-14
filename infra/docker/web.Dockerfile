# The console and the back office: a Flutter web bundle behind nginx.
#
#   docker build -f infra/docker/web.Dockerfile --build-arg APP=console -t bel-console .
#
# **The bundle is built outside this file**, by `tool/images.sh`, and copied
# in. The alternative is a third-party Flutter SDK image in the build stage —
# two to three gigabytes to pull, on a repository whose CI already has the
# Flutter SDK installed for the widget suites. So the coupling is real and it
# lives in one place: `tool/images.sh --web` runs the build and then this.
# Building this Dockerfile by hand without that step fails on the COPY, which
# is the right way round.
#
# **These images are environment-specific and that is not a mistake.** The API
# URL, the Firebase project and its web API key are `String.fromEnvironment`
# in Dart — compile-time, because a Flutter web app has no environment to read
# at runtime. So the URL is baked in, an image built for staging is a staging
# image, and the tag has to say so. The alternative is a bundle that fetches a
# config file before it can do anything, which is one more request on the
# critical path of a login and one more thing to get wrong.
ARG APP=console

FROM nginxinc/nginx-unprivileged:1-alpine

ARG APP
LABEL org.opencontainers.image.title="BilletEnLigne ${APP}"

COPY infra/docker/web.nginx.conf /etc/nginx/conf.d/default.conf
COPY apps/${APP}/build/web /usr/share/nginx/html

EXPOSE 8080
