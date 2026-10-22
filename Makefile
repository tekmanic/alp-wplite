TOPDIR=$(PWD)
IMAGE=alp-wplite:latest
CONTAINER=alp-wplite
VOLUME=wplite-content
PORT=8081

.PHONY: all build run scan clean
all: build run

build:
	docker build -t $(IMAGE) .

run: build
	docker run -d \
        --net="bridge" \
        --name=$(CONTAINER) \
        -p $(PORT):80 \
        -e SERVER_NAME=localhost \
        -e URL="http://localhost:$(PORT)" \
        -e ADMIN_NAME=admin \
        -e ADMIN_EMAIL=admin@domain.com \
        -e TITLE='alp-wplite' \
        -e THEME=twentytwentyfour \
        -v $(VOLUME):/usr/src/wordpress/wp-content \
        $(IMAGE)

# Roll the image forward to the latest stable WordPress (rebuild + recreate,
# preserving the wp-content volume). Safe to run repeatedly.
update:
	bash update.sh

scan:
	trivy image --severity HIGH,CRITICAL $(IMAGE) > scanresults

clean:
	docker stop $(CONTAINER) 2>/dev/null || true
	docker rm -f $(CONTAINER) 2>/dev/null || true
