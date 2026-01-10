# 固定IPを使用するコンテナ（優先起動）
PRIORITY_DIRS := traefik-proxy/ wireguard/

# その他のディレクトリ
ALL_DIRS := $(wildcard */)
REMAINING_DIRS := $(filter-out $(PRIORITY_DIRS),$(ALL_DIRS))

up:
        @echo "=== Starting containers with fixed IPs first ==="
        @for d in $(PRIORITY_DIRS); do \
          if [ -f $$d/docker-compose.yml ]; then \
            echo "=== $$d ==="; \
            (cd $$d && docker compose up -d); \
          fi; \
        done
        @echo ""
        @echo "=== Starting remaining containers ==="
        @for d in $(REMAINING_DIRS); do \
          if [ -f $$d/docker-compose.yml ]; then \
            echo "=== $$d ==="; \
            (cd $$d && docker compose up -d); \
          fi; \
        done

down:
        @for d in $(ALL_DIRS); do \
          if [ -f $$d/docker-compose.yml ]; then \
            echo "=== $$d ==="; \
            (cd $$d && docker compose down); \
          fi; \
        done
