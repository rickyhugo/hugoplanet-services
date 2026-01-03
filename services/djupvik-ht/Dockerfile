FROM scratch
ARG TARGETPLATFORM
LABEL org.opencontainers.image.source=https://github.com/rickyhugo/hugoplanet-services
COPY zig-out/bin/${TARGETPLATFORM}/djupvik_ht /djupvik_ht
ENTRYPOINT ["/djupvik_ht"]
