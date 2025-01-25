import pytest
import requests
import os
from openai import OpenAI, OpenAIError
from typing import Dict, Any, Tuple, List
from dotenv import load_dotenv
import uuid
import json

load_dotenv()
base_url = os.getenv("API_ENDPOINT")
api_key = os.getenv("API_KEY")


def get_completion(
    client: OpenAI,
    prompt: str,
    model: str = "anthropic.claude-3-5-sonnet-20241022-v2:0",
    extra_body: Dict[str, Any] = None,
) -> Tuple[str, str]:
    """
    Gets a complete response from the API in a single request.
    Returns a tuple of (content, session_id).
    """
    if extra_body is None:
        extra_body = {}

    response = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        stream=False,
        extra_body=extra_body,
    )

    session_id = response.model_extra.get("session_id")
    content = response.choices[0].message.content
    return content, session_id


class TestAPIIntegration:

    def create_test_user(
        self,
        max_budget: float = None,
        budget_duration: str = None,
        models: List[str] = None,
        model_max_budget: Dict[str, float] = None,
        model_rpm_limit: Dict[str, int] = None,
        model_tpm_limit: Dict[str, int] = None,
        rpm_limit: int = None,
        tpm_limit: int = None,
        max_parallel_requests: int = None,
    ) -> Dict:
        """Helper method to create a test user with optional parameters"""
        test_email = f"test_user_{uuid.uuid4()}@example.com"

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        }

        payload = {"user_email": test_email, "user_role": "internal_user"}

        if max_budget is not None:
            payload["max_budget"] = max_budget
        if budget_duration is not None:
            payload["budget_duration"] = budget_duration
        if models is not None:
            payload["models"] = models
        if model_max_budget is not None:
            payload["model_max_budget"] = model_max_budget
        if model_rpm_limit is not None:
            payload["model_rpm_limit"] = model_rpm_limit
        if model_tpm_limit is not None:
            payload["model_tpm_limit"] = model_tpm_limit
        if rpm_limit is not None:
            payload["rpm_limit"] = rpm_limit
        if tpm_limit is not None:
            payload["tpm_limit"] = tpm_limit
        if max_parallel_requests is not None:
            payload["max_parallel_requests"] = max_parallel_requests

        response = requests.post(f"{base_url}/user/new", headers=headers, json=payload)

        print("\nAPI Response Details:")
        print(f"Status Code: {response.status_code}")
        print("\nResponse Headers:")
        for key, value in response.headers.items():
            print(f"  {key}: {value}")
        print("\nResponse Content:")
        try:
            formatted_json = json.dumps(response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(response.text)

        assert (
            response.status_code == 200
        ), f"Failed to create user. Status Code: {response.status_code}. Response: {response.text}"
        return response.json()

    @pytest.fixture
    def test_user(self):
        """Fixture for creating a regular test user with default settings"""
        return self.create_test_user()

    def test_api_flow(self, test_user):
        """Test complete API flow: create user and use their API key"""

        client = OpenAI(
            base_url=base_url,
            api_key=test_user["key"],  # Using the key from user creation response
        )

        try:
            content, session_id = get_completion(
                client, "Hello, this is a test message."
            )

            assert content is not None
            assert session_id is not None

            print(f"Successfully made API call with new user credentials")
            print(f"Response content: {content} Session ID: {session_id}")

        except Exception as e:
            pytest.fail(f"API call failed with new user credentials: {str(e)}")

    def test_zero_budget_user(self):
        """Test that a user with zero budget fails on the second API call"""
        # Create user with zero budget
        zero_budget_user = self.create_test_user(max_budget=0, budget_duration="1mo")

        # Verify budget settings in response
        assert zero_budget_user["max_budget"] == 0, "Max budget should be 0"
        assert (
            zero_budget_user["budget_duration"] == "1mo"
        ), "Budget duration should be 1mo"

        # Initialize client with zero budget user's key
        client = OpenAI(
            base_url=base_url,
            api_key=zero_budget_user["key"],
        )

        # First call should succeed (spend == 0)
        try:
            content, session_id = get_completion(
                client, "This is the first call and should succeed."
            )
            print(f"First call succeeded as expected")
            print(f"First call content: {content}")
            print(f"First call session ID: {session_id}")
        except Exception as e:
            pytest.fail(f"First API call should have succeeded but failed: {str(e)}")

        # Second call should fail due to budget
        with pytest.raises(OpenAIError) as exc_info:
            get_completion(client, "This second call should fail due to zero budget.")

        # Verify error message indicates budget issue
        error_message = str(exc_info.value).lower()
        assert any(
            keyword in error_message for keyword in ["budget", "spend", "limit"]
        ), f"Expected budget-related error, got: {error_message}"

        print(f"Successfully verified that second call fails due to zero budget")
        print(f"Error message: {str(exc_info.value)}")

    def test_model_access_restrictions(self):
        """Test that a user can only access their allowed models"""
        # Define allowed and restricted models
        allowed_models = [
            "anthropic.claude-3-5-sonnet-20240620-v1:0",
        ]
        restricted_model = (
            "anthropic.claude-3-haiku-20240307-v1:0"  # A model not in the allowed list
        )

        # Create user with specific model access
        restricted_user = self.create_test_user(models=allowed_models)

        # Verify models list in response
        assert set(restricted_user["models"]) == set(
            allowed_models
        ), "User's allowed models don't match the requested models"

        client = OpenAI(
            base_url=base_url,
            api_key=restricted_user["key"],
        )

        # Test access to allowed model
        try:
            content, session_id = get_completion(
                client,
                "This call should succeed with an allowed model.",
                model=allowed_models[0],
            )
            print(f"Successfully called allowed model: {allowed_models[0]}")
            print(f"Response content: {content}")
            print(f"Session ID: {session_id}")
        except Exception as e:
            pytest.fail(
                f"Call to allowed model should have succeeded but failed: {str(e)}"
            )

        # Test access to restricted model
        with pytest.raises(OpenAIError) as exc_info:
            get_completion(
                client,
                "This call should fail due to model restriction.",
                model=restricted_model,
            )

        # Verify error message indicates model access issue
        error_message = str(exc_info.value).lower()
        assert any(
            keyword in error_message for keyword in ["model", "access", "permission"]
        ), f"Expected model access error, got: {error_message}"

        print(f"Successfully verified model access restrictions")
        print(f"Error message for restricted model: {str(exc_info.value)}")

    def test_model_rate_limits(self):
        """Test creating a user with specific model RPM and TPM limits"""
        # Define models and their limits
        model1 = "anthropic.claude-3-5-sonnet-20240620-v1:0"
        model2 = "anthropic.claude-3-haiku-20240307-v1:0"

        model_rpm_limit = {model1: 1, model2: 1}
        model_tpm_limit = {model1: 10000, model2: 20000}

        # Create user with rate limits
        user = self.create_test_user(
            model_rpm_limit=model_rpm_limit, model_tpm_limit=model_tpm_limit
        )

        # Verify RPM limits in response
        assert user["model_rpm_limit"][model1] == 1, f"Incorrect RPM limit for {model1}"
        assert user["model_rpm_limit"][model2] == 1, f"Incorrect RPM limit for {model2}"

        # Verify TPM limits in response
        assert (
            user["model_tpm_limit"][model1] == 10000
        ), f"Incorrect TPM limit for {model1}"
        assert (
            user["model_tpm_limit"][model2] == 20000
        ), f"Incorrect TPM limit for {model2}"

        print("\nSuccessfully verified model rate limits:")
        print(f"Model RPM limits: {json.dumps(user['model_rpm_limit'], indent=2)}")
        print(f"Model TPM limits: {json.dumps(user['model_tpm_limit'], indent=2)}")

    def test_user_rate_limits(self):
        """Test creating a user with specific TPM and RPM limits"""
        # Define rate limits
        tpm_limit = 10000
        rpm_limit = 10
        max_parallel_requests = 2

        # Create user with rate limits
        user = self.create_test_user(
            tpm_limit=tpm_limit,
            rpm_limit=rpm_limit,
            max_parallel_requests=max_parallel_requests,
        )

        # Verify limits in response
        assert (
            user["tpm_limit"] == tpm_limit
        ), f"Incorrect TPM limit. Expected {tpm_limit}, got {user['tpm_limit']}"
        assert (
            user["rpm_limit"] == rpm_limit
        ), f"Incorrect RPM limit. Expected {rpm_limit}, got {user['rpm_limit']}"

        print("\nSuccessfully verified user rate limits:")
        print(f"TPM limit: {user['tpm_limit']}")
        print(f"RPM limit: {user['rpm_limit']}")
