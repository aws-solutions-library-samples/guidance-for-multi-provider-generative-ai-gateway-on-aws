# Dockerfile

FROM python:3.13-slim

WORKDIR /app

# Install system dependencies if needed
# RUN apt-get update && apt-get install -y ...

COPY requirements.txt /app/requirements.txt

RUN pip install --no-cache-dir -r requirements.txt

COPY . /app

# Expose the port; ECS will map it
EXPOSE 8080

CMD ["python", "fake_openai_server.py"]
