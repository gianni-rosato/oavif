IMAGE=oavif-build

binary: docker-build
	mkdir -p bin
	docker create --name tmp $(IMAGE)
	docker cp tmp:/oavif bin/oavif
	docker rm tmp

docker-build:
	docker build --progress=plain -t $(IMAGE) .

clean:
	rm -f bin
	docker rmi $(IMAGE) || true