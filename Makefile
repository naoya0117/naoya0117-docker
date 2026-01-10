DIRS := $(wildcard */)

up:
	for d in $(DIRS); do \
	  if [ -f $$d/docker-compose.yml ]; then \
	    echo "=== $$d ==="; \
	    (cd $$d && docker compose up -d); \
	  fi; \
	done

down:
	for d in $(DIRS); do \
	  if [ -f $$d/docker-compose.yml ]; then \
	    echo "=== $$d ==="; \
	    (cd $$d && docker compose down); \
	  fi; \
	done
