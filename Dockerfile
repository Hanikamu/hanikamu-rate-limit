# Base image
FROM ruby:4.0

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
  libpq-dev postgresql-client \
  && rm -rf /var/lib/apt/lists/*

WORKDIR "/app"

# Add our Gemfile and install gems
ADD Gemfile* ./
ADD hanikamu-rate-limit.gemspec ./
ADD lib ./lib

RUN bundle install

# Copy the rest of the application
ADD . .
