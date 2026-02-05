.PHONY: shell
shell: ## access to the system console
	 docker-compose run --rm app bash

.PHONY: build
build: ## build the image
	docker-compose build

.PHONY: bundle
bundle: ## install gems and rebuild image
	- docker-compose run --rm app bundle install
	- ${MAKE} build

.PHONY: console
console: ## build the image
		docker-compose run --rm app bash -c "bin/console"

.PHONY: rspec
rspec: ## build the image
	docker-compose run --rm app bash -c "bundle exec rspec"


.PHONY: cops
cops: ## build the image
	docker-compose run --rm app sh -c "bundle exec rubocop -A"
