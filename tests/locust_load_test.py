import os
import uuid
from locust import HttpUser, task, between
from dotenv import load_dotenv

load_dotenv()

base_url = os.getenv("API_ENDPOINT")
api_key = os.getenv("API_KEY")


class MyUser(HttpUser):
    host = base_url
    wait_time = between(0.5, 1)  # Random wait time between requests

    @task(100)
    def litellm_completion(self):
        # no cache hits with this
        payload = {
            "model": "fake-openai-endpoint",
            "messages": [
                {
                    "role": "user",
                    "content": f"{uuid.uuid4()} This is a test there will be no cache hits and we'll fill up the context"
                    * 150,
                }
            ],
        }
        response = self.client.post("/chat/completions", json=payload)
        if response.status_code != 200:
            # log the errors in error.txt
            with open("error.txt", "a") as error_log:
                error_log.write(response.text + "\n")

    def on_start(self):
        self.api_key = api_key
        self.client.headers.update({"Authorization": f"Bearer {self.api_key}"})
