# Static musl binary in an empty image. The build stage runs on the build host's platform and
# cross-compiles for TARGETPLATFORM (linux/amd64 or linux/arm64), so an arm64 image builds without
# emulating rustc.
FROM --platform=$BUILDPLATFORM rust:1.74-slim-bookworm AS build

ARG TARGETARCH

# 1. Rust target and cross linker for the image's architecture. The crate has no C dependencies, so
#    only the final link needs a linker for that architecture.
RUN case "$TARGETARCH" in \
        amd64) echo x86_64-unknown-linux-musl > /rust-target; echo x86-64 > /gcc-arch ;; \
        arm64) echo aarch64-unknown-linux-musl > /rust-target; echo aarch64 > /gcc-arch ;; \
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac
RUN apt-get update \
    && apt-get install -y --no-install-recommends "gcc-$(cat /gcc-arch)-linux-gnu" libc6-dev \
    && rm -rf /var/lib/apt/lists/*
RUN rustup target add "$(cat /rust-target)"

# 2. setup app user
ENV USER=guest
ENV UID=10001

RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

# 3. Create a new empty shell project
RUN cargo new --bin modbus-proxy-rs
WORKDIR /modbus-proxy-rs

# 4. Copy our manifests
COPY ./Cargo.lock ./Cargo.lock
COPY ./Cargo.toml ./Cargo.toml

# 5. Build only the dependencies to cache them. The linker is the cross gcc for the target, named
#    like x86_64-linux-gnu-gcc; Cargo reads it from CARGO_TARGET_<TRIPLE>_LINKER.
RUN target=$(cat /rust-target) \
    && export "CARGO_TARGET_$(echo "$target" | tr 'a-z-' 'A-Z_')_LINKER=$(echo "$target" | cut -d- -f1)-linux-gnu-gcc" \
    && cargo build --locked --target "$target" --release
RUN rm src/*.rs

# 6. Now that the dependency is built, copy your source code
COPY ./src ./src

# 7. Build for release, into a path that does not depend on the target
RUN target=$(cat /rust-target) \
    && export "CARGO_TARGET_$(echo "$target" | tr 'a-z-' 'A-Z_')_LINKER=$(echo "$target" | cut -d- -f1)-linux-gnu-gcc" \
    && rm ./target/"$target"/release/deps/modbus_proxy_rs* \
    && cargo build --locked --target "$target" --release \
    && cp ./target/"$target"/release/modbus-proxy-rs /modbus-proxy-rs-bin

# our final base
FROM scratch

COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# Run as guest user
USER guest:guest

# Copy the build artifact from the build stage. Cargo.toml's release profile already strips it.
COPY --from=build /modbus-proxy-rs-bin ./modbus-proxy-rs

# Set the startup command to run
ENTRYPOINT ["./modbus-proxy-rs"]
CMD ["-c", "/etc/modbus-proxy.yml"]
