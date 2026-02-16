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

.PHONY: dummy
dummy: ## generate the dummy Rails app for UI preview
	docker-compose run --rm app bash -c "\
		rm -rf spec/dummy && \
		bundle exec rails new spec/dummy \
			--skip-bundle --skip-active-record --skip-action-mailer \
			--skip-action-mailbox --skip-action-text --skip-active-storage \
			--skip-action-cable --skip-javascript --skip-hotwire \
			--skip-asset-pipeline --skip-jbuilder --skip-system-test \
			--skip-test --skip-bootsnap --skip-ci --skip-rubocop && \
		rm -rf spec/dummy/.git && \
		cp spec/dummy_config/Gemfile spec/dummy/Gemfile && \
		cp spec/dummy_config/config/application.rb spec/dummy/config/application.rb && \
		cp spec/dummy_config/config/boot.rb spec/dummy/config/boot.rb && \
		cp spec/dummy_config/config/puma.rb spec/dummy/config/puma.rb && \
		cp spec/dummy_config/config/routes.rb spec/dummy/config/routes.rb && \
		mkdir -p spec/dummy/config/initializers && \
		cp spec/dummy_config/config/initializers/hanikamu_rate_limit.rb spec/dummy/config/initializers/hanikamu_rate_limit.rb && \
		mkdir -p spec/dummy/script && \
		cp spec/dummy_config/script/seed_rate_limits.rb spec/dummy/script/seed_rate_limits.rb \
	"

.PHONY: dummy-server
dummy-server: dummy ## run the dummy Rails app with seed traffic
	docker-compose run --rm -p 3000:3000 app bash -c "\
		cd spec/dummy && bundle install && \
		(bundle exec ruby script/seed_rate_limits.rb &) && \
		bundle exec rails s -b 0.0.0.0 -p 3000 \
	"

.PHONY: dummy-seed
dummy-seed: dummy ## generate dummy rate limit traffic (standalone)
	docker-compose run --rm app bash -c "bundle exec ruby spec/dummy/script/seed_rate_limits.rb"

.PHONY: down
down: ## stop all running containers
	docker-compose down


.PHONY: cops
cops: ## build the image
	docker-compose run --rm app sh -c "bundle exec rubocop -A"
