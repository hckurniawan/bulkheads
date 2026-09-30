# bulkhead has no build step: these targets only call the repository's scripts,
# which also work without make.

.PHONY: test install

# Run every test file, or only some: make test ONLY="deps lint"
test:
	tests/run $(ONLY)

# Install bulkhead from this checkout, which is then used in place (see install.sh).
install:
	./install.sh
