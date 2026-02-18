# =============================================================================
# Cok — Development Makefile
# =============================================================================

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
# Configuration (override via environment or command line, e.g. HTTP_PORT=9090)
# -----------------------------------------------------------------------------
TEST_SECRET    ?= test-secret-key-minimum-32-characters
TEST_SUBDOMAIN ?= test-client
LOCAL_PORT     ?= 3000
HTTP_PORT      ?= 8080
TCP_PORT       ?= 5000

BINARY_DIR      := .build/release
SERVER_BIN      := $(BINARY_DIR)/cok-server
CLIENT_BIN      := $(BINARY_DIR)/cok
API_KEY_FILE    := .api_key.tmp
PID_FILE        := .server.pid
TEST_SITE_DIR   := .test-site
IMAGE_TAG       ?= cok-server:dev

# Script to generate an API key — extracted to avoid running at parse time
GENERATE_KEY_CMD = swift Scripts/generate-api-key.swift $(TEST_SUBDOMAIN) $(TEST_SECRET) 2>&1 \
                   | grep -Eo '[0-9a-f]{64}' | head -1

# Terminal colors (gracefully degrade if tput unavailable)
BOLD  := $(shell tput bold 2>/dev/null)
BLUE  := $(shell tput setaf 4 2>/dev/null)
GREEN := $(shell tput setaf 2 2>/dev/null)
YELLOW:= $(shell tput setaf 3 2>/dev/null)
RED   := $(shell tput setaf 1 2>/dev/null)
RESET := $(shell tput sgr0 2>/dev/null)

# Helpers
_banner = @printf '$(BLUE)%s$(RESET)\n' '══════════════════════════════════════'
_ok     = @printf '$(GREEN)✓ %s$(RESET)\n'
_info   = @printf '$(YELLOW)  %s$(RESET)\n'

# Server environment block (re-used by multiple targets)
define SERVER_ENV
HTTP_PORT=$(HTTP_PORT) \
TCP_PORT=$(TCP_PORT) \
BASE_DOMAIN=localhost \
API_KEY_SECRET=$(TEST_SECRET) \
MAX_TUNNELS=10
endef

# =============================================================================
# Phony targets
# =============================================================================
.PHONY: help \
        build build-server build-client \
        test unit-test \
        server client generate-key \
        server-bg server-stop status \
        dev test-site \
        docker-build docker-run \
        clean

# =============================================================================
# Help
# =============================================================================
help: ## Show this help
	@printf '$(BOLD)$(BLUE)Cok Development Commands$(RESET)\n\n'
	@awk 'BEGIN { FS = ":.*##" } \
	      /^[a-zA-Z_-]+:.*##/ { \
	          printf "  $(GREEN)%-18s$(RESET) %s\n", $$1, $$2 \
	      } \
	      /^##@/ { \
	          printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5) \
	      }' $(MAKEFILE_LIST)
	@printf '\n$(YELLOW)Override variables:$(RESET)  HTTP_PORT=8080  TCP_PORT=5000  LOCAL_PORT=3000\n\n'

# =============================================================================
##@ Build
# =============================================================================
build: build-server build-client ## Build both binaries (release)

build-server: ## Build cok-server (release)
	@printf '$(BLUE)Building cok-server...$(RESET)\n'
	@swift build -c release --product cok-server
	$(_ok) "cok-server built → $(SERVER_BIN)"

build-client: ## Build cok client (release)
	@printf '$(BLUE)Building cok...$(RESET)\n'
	@swift build -c release --product cok
	$(_ok) "cok built → $(CLIENT_BIN)"

# =============================================================================
##@ Test
# =============================================================================
unit-test: ## Run unit tests
	@printf '$(BLUE)Running tests...$(RESET)\n'
	@swift test --parallel
	$(_ok) "All tests passed"

test: unit-test ## Alias for unit-test

# =============================================================================
##@ Development
# =============================================================================
generate-key: ## Generate a test API key and cache it in $(API_KEY_FILE)
	@printf '$(BLUE)Generating API key for subdomain "$(TEST_SUBDOMAIN)"...$(RESET)\n'
	@API_KEY=$$($(GENERATE_KEY_CMD)); \
	if [ -z "$$API_KEY" ]; then \
		printf '$(RED)Error: key generation failed$(RESET)\n'; exit 1; \
	fi; \
	printf '%s' "$$API_KEY" > $(API_KEY_FILE); \
	printf '$(GREEN)✓ API key: %s$(RESET)\n' "$$API_KEY"

# Internal: ensure a key exists (generate only if not cached)
$(API_KEY_FILE):
	@$(MAKE) --no-print-directory generate-key

server: build-server ## Start the development server (foreground)
	$(_banner)
	@printf '$(BLUE)  cok-server$(RESET)\n'
	$(_banner)
	$(_info) "HTTP → http://localhost:$(HTTP_PORT)"
	$(_info) "TCP  → localhost:$(TCP_PORT)"
	$(_info) "Secret: $(TEST_SECRET)"
	@printf '\n'
	@$(SERVER_ENV) $(SERVER_BIN)

server-bg: build-server ## Start the server in the background; PID saved to $(PID_FILE)
	@printf '$(BLUE)Starting server in background...$(RESET)\n'
	@$(SERVER_ENV) $(SERVER_BIN) & echo $$! > $(PID_FILE)
	@sleep 2
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		printf '$(GREEN)✓ Server started (PID %s)$(RESET)\n' "$$(cat $(PID_FILE))"; \
		printf '$(YELLOW)  Stop with: make server-stop$(RESET)\n'; \
	else \
		printf '$(RED)✗ Server failed to start$(RESET)\n'; exit 1; \
	fi

server-stop: ## Stop background server
	@if [ -f $(PID_FILE) ]; then \
		PID=$$(cat $(PID_FILE)); \
		kill "$$PID" 2>/dev/null && printf '$(GREEN)✓ Server stopped (PID %s)$(RESET)\n' "$$PID"; \
		rm -f $(PID_FILE); \
	else \
		printf '$(YELLOW)No server PID file found$(RESET)\n'; \
	fi

client: build-client $(API_KEY_FILE) ## Connect client to local server
	$(_banner)
	@printf '$(BLUE)  cok client$(RESET)\n'
	$(_banner)
	$(_info) "Server:    localhost:$(TCP_PORT)"
	$(_info) "Subdomain: $(TEST_SUBDOMAIN)"
	$(_info) "Local:     http://localhost:$(LOCAL_PORT)"
	$(_info) "Public:    http://$(TEST_SUBDOMAIN).localhost:$(HTTP_PORT)"
	@printf '\n'
	@$(CLIENT_BIN) \
		--port $(LOCAL_PORT) \
		--subdomain $(TEST_SUBDOMAIN) \
		--api-key $$(cat $(API_KEY_FILE)) \
		--server localhost:$(TCP_PORT)

test-site: ## Serve a static test page on $(LOCAL_PORT) via python3
	@printf '$(BLUE)Starting test HTTP server on port $(LOCAL_PORT)...$(RESET)\n'
	@mkdir -p $(TEST_SITE_DIR)
	@printf '<h1>Hello from Cok!</h1><p>Served via TCP tunnel. Time: %s</p>' \
	    "$$(date)" > $(TEST_SITE_DIR)/index.html
	$(_ok) "Test site → http://localhost:$(LOCAL_PORT)"
	@cd $(TEST_SITE_DIR) && python3 -m http.server $(LOCAL_PORT)

dev: ## Full dev workflow: start server in bg, print next steps
	@$(MAKE) --no-print-directory server-bg
	@$(MAKE) --no-print-directory generate-key
	@printf '\n$(BOLD)Next steps:$(RESET)\n'
	$(_info) "Terminal 2: make test-site"
	$(_info) "Terminal 3: make client"
	$(_info) "Browser:    http://$(TEST_SUBDOMAIN).localhost:$(HTTP_PORT)"
	@printf '\n'

status: ## Show server and API key status
	@printf '$(BLUE)Status$(RESET)\n'
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		printf '$(GREEN)  Server  running (PID %s)$(RESET)\n' "$$(cat $(PID_FILE))"; \
	else \
		printf '$(YELLOW)  Server  not running$(RESET)\n'; \
	fi
	@if [ -f $(API_KEY_FILE) ]; then \
		printf '$(GREEN)  API key %s$(RESET)\n' "$$(cat $(API_KEY_FILE))"; \
	else \
		printf '$(YELLOW)  API key not generated$(RESET)\n'; \
	fi

# =============================================================================
##@ Docker
# =============================================================================
docker-build: ## Build Docker server image (tag: $(IMAGE_TAG))
	@printf '$(BLUE)Building Docker image $(IMAGE_TAG)...$(RESET)\n'
	@docker build -t $(IMAGE_TAG) .
	$(_ok) "Image built: $(IMAGE_TAG)"

docker-run: docker-build ## Build and run server image
	@printf '$(BLUE)Running $(IMAGE_TAG)...$(RESET)\n'
	@docker run --rm \
		-p $(HTTP_PORT):8080 \
		-p $(TCP_PORT):5000 \
		-e API_KEY_SECRET=$(TEST_SECRET) \
		-e BASE_DOMAIN=localhost \
		$(IMAGE_TAG)

# =============================================================================
##@ Housekeeping
# =============================================================================
clean: server-stop ## Remove build artifacts, caches, and temp files
	@printf '$(BLUE)Cleaning...$(RESET)\n'
	@swift package clean
	@rm -f $(API_KEY_FILE) $(PID_FILE)
	@rm -rf $(TEST_SITE_DIR)
	$(_ok) "Clean complete"