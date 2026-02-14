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
		if [ ! -d spec/dummy ]; then \
			bundle exec rails new spec/dummy \
				--skip-bundle --skip-active-record --skip-action-mailer \
				--skip-action-mailbox --skip-action-text --skip-active-storage \
				--skip-action-cable --skip-javascript --skip-hotwire \
				--skip-sprockets --skip-jbuilder --skip-system-test \
				--skip-test --skip-bootsnap --skip-ci --skip-rubocop && \
			rm -rf spec/dummy/.git; \
		fi && \
		cp spec/dummy_config/Gemfile spec/dummy/Gemfile && \
		cp spec/dummy_config/config/application.rb spec/dummy/config/application.rb && \
		cp spec/dummy_config/config/routes.rb spec/dummy/config/routes.rb && \
		mkdir -p spec/dummy/config/initializers && \
		cp spec/dummy_config/config/initializers/hanikamu_rate_limit.rb spec/dummy/config/initializers/hanikamu_rate_limit.rb && \
		mkdir -p spec/dummy/script && \
		cp spec/dummy_config/script/seed_rate_limits.rb spec/dummy/script/seed_rate_limits.rb \
	"

.PHONY: dummy-server
dummy-server: dummy ## run the dummy Rails app to preview the UI
	docker-compose run --rm -p 3000:3000 app bash -c "cd spec/dummy && bundle install && bundle exec rails s -b 0.0.0.0 -p 3000"

.PHONY: dummy-seed
dummy-seed: dummy ## generate dummy rate limit traffic for the UI dashboard
	docker-compose run --rm app bash -c "bundle exec ruby spec/dummy/script/seed_rate_limits.rb"


.PHONY: cops
cops: ## build the image
	docker-compose run --rm app sh -c "bundle exec rubocop -A"
