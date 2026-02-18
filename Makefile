# Cok Development Makefile
# Easy testing and development commands

# Configuration
TEST_SECRET = test-secret-key-minimum-32-characters
TEST_SUBDOMAIN = test-client
LOCAL_PORT = 3000
HTTP_PORT = 8080
TCP_PORT = 5000

# Generate API key from test credentials (cached)
TEST_API_KEY := $(shell swift Scripts/generate-api-key.swift $(TEST_SUBDOMAIN) $(TEST_SECRET) 2>&1 | grep -Eo '[0-9a-f]{64}' | head -1)

# Colors for output
BLUE = \033[34m
GREEN = \033[32m
YELLOW = \033[33m
RED = \033[31m
NC = \033[0m # No Color

.PHONY: help build make-server make-client server client test-server test-client generate-key test-site clean all

help: ## Show this help message
	@echo "$(BLUE)Cok Development Commands:$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"}; /^[a-zA-Z_-]+:.*##/ { printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(YELLOW)Quick Start:$(NC)"
	@echo "  make make-server  # Start server with test credentials"
	@echo "  make make-client  # In another terminal, connect matching client"

build: ## Build both server and client
	@echo "$(BLUE)Building Cok binaries...$(NC)"
	@swift build -c release --product cok-server
	@swift build -c release --product cok
	@echo "$(GREEN)✓ Build complete$(NC)"

unit-test: ## Run unit tests
	@echo "$(BLUE)Running unit tests...$(NC)"
	@swift test
	@echo "$(GREEN)✓ Tests passed$(NC)"

make-server: build ## Run test server with predefined auth key
	@rm -f .api_key.tmp
	@echo "$(BLUE)═══════════════════════════════════════$(NC)"
	@echo "$(BLUE)  Starting Cok Test Server$(NC)"
	@echo "$(BLUE)═══════════════════════════════════════$(NC)"
	@echo "$(GREEN)HTTP Server:$(NC)  http://localhost:$(HTTP_PORT)"
	@echo "$(GREEN)TCP Port:$(NC)    localhost:$(TCP_PORT)"
	@echo "$(GREEN)Base Domain:$(NC)  localhost"
	@echo "$(GREEN)API Secret:$(NC)   $(TEST_SECRET)"
	@echo "$(YELLOW)Generating test API key for subdomain: $(TEST_SUBDOMAIN)$(NC)"
	@echo "$(BLUE)═══════════════════════════════════════$(NC)"
	@echo ""
	@HTTP_PORT=$(HTTP_PORT) \
	TCP_PORT=$(TCP_PORT) \
	BASE_DOMAIN=localhost \
	API_KEY_SECRET=$(TEST_SECRET) \
	TEST_SUBDOMAIN=$(TEST_SUBDOMAIN) \
	MAX_TUNNELS=10 \
	.build/release/cok-server

make-client: build ## Run test client matching server credentials
	@if [ ! -f .api_key.tmp ]; then \
		echo "$(RED)Error: API key not found. Run 'make make-server' first.$(NC)"; \
		exit 1; \
	fi
	@API_KEY=$$(cat .api_key.tmp); \
	echo "$(BLUE)═══════════════════════════════════════$(NC)"; \
	echo "$(BLUE)  Starting Cok Test Client$(NC)"; \
	echo "$(BLUE)═══════════════════════════════════════$(NC)"; \
	echo "$(GREEN)Server:$(NC)       localhost:$(TCP_PORT)"; \
	echo "$(GREEN)Subdomain:$(NC)    $(TEST_SUBDOMAIN)"; \
	echo "$(GREEN)Local Port:$(NC)   $(LOCAL_PORT)"; \
	echo "$(GREEN)Public URL:$(NC)   http://$(TEST_SUBDOMAIN).localhost:$(HTTP_PORT)"; \
	echo "$(YELLOW)API Key:$(NC)      $$API_KEY"; \
	echo "$(BLUE)═══════════════════════════════════════$(NC)"; \
	echo ""; \
	.build/release/cok \
		--port $(LOCAL_PORT) \
		--subdomain $(TEST_SUBDOMAIN) \
		--api-key $$API_KEY \
		--server localhost:$(TCP_PORT)

server: build ## Build and start the development server
	@echo "$(BLUE)Starting Cok server...$(NC)"
	@echo "$(YELLOW)Server URL: localhost:$(TCP_PORT)$(NC)"
	@echo "$(YELLOW)HTTP URL: http://localhost:$(HTTP_PORT)$(NC)"
	@echo "$(YELLOW)API Secret: $(TEST_SECRET)$(NC)"
	@echo ""
	HTTP_PORT=$(HTTP_PORT) \
	TCP_PORT=$(TCP_PORT) \
	BASE_DOMAIN=localhost \
	API_KEY_SECRET=$(TEST_SECRET) \
	MAX_TUNNELS=10 \
	.build/release/cok-server

test-server: build ## Start server in background for testing
	@echo "$(BLUE)Starting test server in background...$(NC)"
	@HTTP_PORT=$(HTTP_PORT) \
	TCP_PORT=$(TCP_PORT) \
	BASE_DOMAIN=localhost \
	API_KEY_SECRET=$(TEST_SECRET) \
	MAX_TUNNELS=10 \
	.build/release/cok-server &
	@echo $$! > .server.pid
	@sleep 2
	@echo "$(GREEN)✓ Server started (PID: $$(cat .server.pid))$(NC)"
	@echo "$(YELLOW)Use 'make stop-server' to stop it$(NC)"

stop-server: ## Stop background test server
	@if [ -f .server.pid ]; then \
		kill $$(cat .server.pid) 2>/dev/null || true; \
		rm -f .server.pid; \
		echo "$(GREEN)✓ Server stopped$(NC)"; \
	else \
		echo "$(YELLOW)No server PID found$(NC)"; \
	fi

generate-key: ## Generate API key for testing
	@echo "$(BLUE)Generating API key...$(NC)"
	@API_KEY=$$(swift Scripts/generate-api-key.swift $(TEST_SUBDOMAIN) $(TEST_SECRET) 2>&1 | grep -Eo '[0-9a-f]{64}' | head -1); \
	echo "$$API_KEY" > .api_key.tmp; \
	echo "$(GREEN)Generated API key: $$API_KEY$(NC)"
	@echo ""
	@echo "$(YELLOW)Use this key with the client:$(NC)"
	@echo "  cok --port $(LOCAL_PORT) --subdomain $(TEST_SUBDOMAIN) --api-key $$(cat .api_key.tmp) --server localhost:$(TCP_PORT)"

client: build generate-key ## Connect client to local server
	@echo "$(BLUE)Connecting client to server...$(NC)"
	@if [ ! -f .api_key.tmp ]; then make generate-key; fi
	@API_KEY=$$(cat .api_key.tmp); \
	echo "$(YELLOW)Connecting with subdomain: $(TEST_SUBDOMAIN)$(NC)"; \
	echo "$(YELLOW)Forwarding: http://$(TEST_SUBDOMAIN).localhost:$(HTTP_PORT) → http://localhost:$(LOCAL_PORT)$(NC)"; \
	echo ""; \
	.build/release/cok --port $(LOCAL_PORT) --subdomain $(TEST_SUBDOMAIN) --api-key $$API_KEY --server localhost:$(TCP_PORT)

test-client: build ## Connect client (assumes server is already running)
	@echo "$(BLUE)Connecting test client...$(NC)"
	@if [ ! -f .api_key.tmp ]; then \
		echo "$(YELLOW)Generating API key...$(NC)"; \
		API_KEY=$$(swift Scripts/generate-api-key.swift $(TEST_SUBDOMAIN) $(TEST_SECRET) 2>&1 | grep -Eo '[0-9a-f]{64}' | head -1); \
		echo "$$API_KEY" > .api_key.tmp; \
	fi
	@API_KEY=$$(cat .api_key.tmp); \
	echo "$(YELLOW)Connecting to: localhost:$(TCP_PORT)$(NC)"; \
	echo "$(YELLOW)Subdomain: $(TEST_SUBDOMAIN)$(NC)"; \
	echo "$(YELLOW)Local port: $(LOCAL_PORT)$(NC)"; \
	echo ""; \
	.build/release/cok --port $(LOCAL_PORT) --subdomain $(TEST_SUBDOMAIN) --api-key $$API_KEY --server localhost:$(TCP_PORT)

test-site: ## Start a simple HTTP server on port 3000 for testing
	@echo "$(BLUE)Starting test HTTP server on port $(LOCAL_PORT)...$(NC)"
	@mkdir -p test-site
	@echo "<h1>Hello from Cok tunnel!</h1><p>This is served via the tunnel</p><p>Time: $$(date)</p>" > test-site/index.html
	@echo "$(GREEN)✓ Test site created$(NC)"
	@echo "$(YELLOW)Starting server on http://localhost:$(LOCAL_PORT)$(NC)"
	@cd test-site && python3 -m http.server $(LOCAL_PORT)

test: test-server generate-key ## Start everything for testing
	@echo "$(GREEN)✓ Development environment ready!$(NC)"
	@echo ""
	@echo "$(YELLOW)Next steps:$(NC)"
	@echo "1. Open a new terminal and run: make test-site"
	@echo "2. Open another terminal and run: make test-client"
	@echo "3. Visit: http://$(TEST_SUBDOMAIN).localhost:$(HTTP_PORT)"
	@echo ""
	@echo "$(YELLOW)API Key generated: $$(cat .api_key.tmp)$(NC)"

all: build test ## Build and setup complete test environment
	@echo "$(GREEN)🚀 Ready for testing!$(NC)"

clean: ## Clean build artifacts and temp files
	@echo "$(BLUE)Cleaning up...$(NC)"
	@swift package clean
	@rm -f .api_key.tmp .server.pid
	@rm -rf test-site
	@echo "$(GREEN)✓ Cleaned$(NC)"

# Development helpers
logs: ## Show recent server logs (if running)
	@tail -f /dev/null  # This would need actual log file path

status: ## Show running processes
	@echo "$(BLUE)Checking status...$(NC)"
	@if [ -f .server.pid ]; then \
		echo "$(GREEN)Server running (PID: $$(cat .server.pid))$(NC)"; \
	else \
		echo "$(YELLOW)No server running$(NC)"; \
	fi
	@if [ -f .api_key.tmp ]; then \
		echo "$(GREEN)API key available: $$(cat .api_key.tmp)$(NC)"; \
	else \
		echo "$(YELLOW)No API key generated$(NC)"; \
	fi

# Docker helpers
docker-build: ## Build Docker server image
	@echo "$(BLUE)Building Docker image...$(NC)"
	docker build -t cok-server:dev .
	@echo "$(GREEN)✓ Docker image built$(NC)"

docker-run: docker-build ## Run server in Docker
	@echo "$(BLUE)Starting server in Docker...$(NC)"
	docker run --rm \
		-p $(HTTP_PORT):8080 \
		-p $(TCP_PORT):5000 \
		-e API_KEY_SECRET=$(TEST_SECRET) \
		-e BASE_DOMAIN=localhost \
		cok-server:dev