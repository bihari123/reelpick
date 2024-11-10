FROM ubuntu:latest

# Install Redis, hiredis, and other essentials
RUN apt-get update && \
  apt-get install -y \
  redis-server \
  libhiredis-dev curl &&  \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Create a non-root user
RUN useradd -m -s /bin/bash appuser && \
  mkdir -p /app && \
  chown appuser:appuser /app


# Make sure Redis can write to its working directory
RUN mkdir -p /var/lib/redis && \
  chown redis:redis /var/lib/redis && \
  chmod 770 /var/lib/redis

# Switch to the non-root user for the application
USER appuser
WORKDIR /app

# Copy the pre-built binary
# Replace 'reelpick' with your actual binary name
COPY --chown=appuser:appuser ./zig-out/bin/reelpick .

# Make the binary executable
RUN chmod +x ./reelpick

# Create a startup script
USER root
RUN echo '#!/bin/bash\nservice redis-server start\nsu - appuser -c "/app/reelpick"' > /start.sh && \
  chmod +x /start.sh

# Command to run both Redis and your application
CMD ["/start.sh"]
