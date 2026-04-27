FROM swift:6.2-noble AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /build
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN set +e; \
    swift build -c release --product PodcastBackend -j 2 2>&1 \
      | tee /tmp/swift-build.log \
      | grep -E "(^error:|^warning:|BUILD|FAILED|Build complete|fatal error|^/build/)" || true; \
    status=${PIPESTATUS[0]}; \
    set -e; \
    if [ "$status" -ne 0 ]; then \
      echo "swift build failed; tailing last 160 lines"; \
      tail -160 /tmp/swift-build.log; \
      exit "$status"; \
    fi

FROM swift:6.2-noble-slim
WORKDIR /app
COPY --from=build /build/.build/release/PodcastBackend /app/PodcastBackend
ENV HOSTNAME=0.0.0.0
ENV PORT=8080
EXPOSE 8080
CMD ["sh", "-c", "./PodcastBackend migrate --yes && ./PodcastBackend serve --hostname 0.0.0.0 --port ${PORT}"]
