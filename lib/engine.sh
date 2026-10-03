# bulkhead — Apple's `container` CLI: the system service, the builder, build contexts.
#
# Engine layer. It may use core.sh; it must never make a Docker Hub (curl) call — that
# is registry.sh's job — and it must not depend on image.sh above it.

# Part of bulkhead's shared library; loaded by lib/common.sh. Source-only — this file
# defines functions and variables and executes nothing.
if [ -n "${_BULKHEAD_ENGINE_SH:-}" ]; then return 0; fi
_BULKHEAD_ENGINE_SH=1

# Resolve this part's own directory so it can pull in what it depends on, making it
# sourceable on its own (handy for testing a layer in isolation). $0 is the wrapper,
# not this file, so BASH_SOURCE is the only reliable handle.
: "${BULKHEAD_LIB_DIR:=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "${BULKHEAD_LIB_DIR}/core.sh"

# Starts the container system service, which has to be running before any other
# `container` command works. `container system start` is idempotent, so calling this
# when the service is already up is harmless.
#
# On a first-ever start with no kernel installed, the command asks before downloading
# the recommended kernel. Stdio is left attached so that prompt reaches the user — but
# when stdin isn't a terminal the prompt can't be answered and the start fails outright,
# so --enable-kernel-install answers it up front in that case. (`system start` already
# pulls the init filesystem image unprompted, so this isn't a new kind of download.)
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_container_start_system() {
	log_info "Starting the container system service..."
	if [ -t 0 ]; then
		container system start
	else
		container system start --enable-kernel-install
	fi
}

# Exits with an error unless Apple's `container` CLI is installed and its system service
# is running, starting the service when it isn't. Only a missing CLI or a service that
# won't come up is fatal — an unstarted service is something we can fix ourselves.
container_require() {
	if ! command -v container >/dev/null 2>&1; then
		log_error "This wrapper requires Apple's \`container\` CLI (Apple silicon, macOS 26+)."
		log_error "Install it from https://github.com/apple/container/releases"
		exit 1
	fi

	container system status >/dev/null 2>&1 && return 0

	if ! _container_start_system; then
		log_error "Could not start the container system service. Try it by hand: container system start"
		exit 1
	fi

	# A clean exit from `system start` isn't proof the service is answering, so confirm.
	if ! container system status >/dev/null 2>&1; then
		log_error "The container system service still isn't responding. Check: container system status"
		exit 1
	fi
}

# Clears the build cache by deleting the builder container, which is where `container`
# keeps it (there is no `builder prune`). It is recreated on demand by the next build.
# Never fatal — a missing builder is the state we want anyway.
container_builder_reset() {
	container builder delete --force >/dev/null 2>&1 || true
}

# Prints a stable empty directory to use as the build context. Every wrapper keeps its
# Dockerfile inline and none of them COPY from the context, so there is nothing to send
# — and `container` syncs the context into the builder VM, which would make passing the
# user's current directory needlessly expensive.
# Internal: not part of the public API, so sources must not call it (see AGENTS.md).
_container_build_context() {
	mkdir -p "${BULKHEAD_SYSTEM_DIR}/empty-context"
	printf '%s' "${BULKHEAD_SYSTEM_DIR}/empty-context"
}
