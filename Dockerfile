FROM ruby:3.2-slim

WORKDIR /app

RUN apt-get update && apt-get install -y build-essential unzip && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN bundle install

COPY . .

RUN bundle exec ruby bin/setup_coastline.rb
RUN test -s data/coastline.geojson && test -s data/interior_water.geojson

EXPOSE 4567
ENV PORT=4567

CMD ["bundle", "exec", "ruby", "app.rb"]
