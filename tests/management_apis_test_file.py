import pytest
import requests
import os
from openai import OpenAI, OpenAIError
from typing import Dict, Any, Tuple, List
from dotenv import load_dotenv
import uuid
import json
import time
from concurrent.futures import ThreadPoolExecutor

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
        teams: List[str] = None,  # New parameter for team assignments
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
        if teams is not None:
            payload["teams"] = teams

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

    def test_key_generation(self):
        # First create a test user
        test_user = self.create_test_user(
            max_budget=100,
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        )

        # Prepare headers for key generation request
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {test_user['key']}",
        }

        # Prepare payload for key generation
        key_payload = {
            "user_id": test_user["user_id"],
            "duration": "7d",  # Key valid for 7 days
            "key_alias": f"test_key_{uuid.uuid4()}",
            "max_budget": 50,  # Lower budget than parent user
            "budget_duration": "7d",
            "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0"],
            "metadata": {"purpose": "testing", "environment": "test"},
        }

        # Make request to generate new key
        response = requests.post(
            f"{base_url}/key/generate", headers=headers, json=key_payload
        )

        print("\nKey Generation Response Details:")
        print(f"Status Code: {response.status_code}")
        print("\nResponse Content:")
        try:
            formatted_json = json.dumps(response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(response.text)

        assert (
            response.status_code == 200
        ), f"Failed to generate key. Status Code: {response.status_code}. Response: {response.text}"

        generated_key = response.json()

        # Verify the generated key's properties
        assert (
            "test_key_" in generated_key["key_alias"]
        ), "Key alias prefix doesn't match"
        assert generated_key["max_budget"] == 50, "Max budget doesn't match"
        assert generated_key["budget_duration"] == "7d", "Budget duration doesn't match"
        assert generated_key["user_id"] == test_user["user_id"], "User ID doesn't match"

        # Test the new key with an API call
        client = OpenAI(
            base_url=base_url,
            api_key=generated_key["key"],
        )

        try:
            content, session_id = get_completion(
                client,
                "Hello, testing with generated key.",
                model="anthropic.claude-3-5-sonnet-20240620-v1:0",
            )

            assert content is not None
            assert session_id is not None

            print(f"\nSuccessfully made API call with generated key")
            print(f"Response content: {content}")
            print(f"Session ID: {session_id}")

        except Exception as e:
            pytest.fail(f"API call failed with generated key: {str(e)}")

    # Broken right now: https://github.com/BerriAI/litellm/issues/8029
    # def test_key_model_privilege_escalation(self):
    #     """Test that a user cannot create a key with access to models they don't have access to"""
    #     # Create a test user with access to only one specific model
    #     allowed_model = "anthropic.claude-3-5-sonnet-20240620-v1:0"
    #     restricted_model = "anthropic.claude-3-haiku-20240307-v1:0"

    #     test_user = self.create_test_user(
    #         max_budget=100,
    #         budget_duration="30d",
    #         models=[allowed_model],  # User only has access to this model
    #     )

    #     # Prepare headers using the test user's key
    #     headers = {
    #         "Content-Type": "application/json",
    #         "Authorization": f"Bearer {test_user['key']}",
    #     }

    #     # Try to generate a key with access to both allowed and restricted models
    #     key_payload = {
    #         "user_id": test_user["user_id"],
    #         "duration": "7d",
    #         "key_alias": f"test_key_{uuid.uuid4()}",
    #         "models": [
    #             allowed_model,
    #             restricted_model,
    #         ],  # Attempting to gain access to restricted model
    #         "metadata": {
    #             "purpose": "testing_privilege_escalation",
    #             "environment": "test",
    #         },
    #     }

    #     # Make request to generate new key
    #     response = requests.post(
    #         f"{base_url}/key/generate", headers=headers, json=key_payload
    #     )

    #     print("\nKey Generation Response Details:")
    #     print(f"Status Code: {response.status_code}")
    #     print("\nResponse Content:")
    #     try:
    #         formatted_json = json.dumps(response.json(), indent=2)
    #         print(formatted_json)
    #     except json.JSONDecodeError:
    #         print(response.text)

    #     # Verify that the request was rejected
    #     assert (
    #         response.status_code == 400
    #     ), "Request should have been rejected with 400 status code"

    #     # Verify error message indicates model access issue
    #     error_message = response.json().get("error", {}).get("message", "").lower()
    #     assert any(
    #         keyword in error_message
    #         for keyword in ["model", "access", "permission", "unauthorized"]
    #     ), f"Expected model access error, got: {error_message}"

    #     # Now try to generate a key with only allowed model to verify valid case still works
    #     key_payload["models"] = [allowed_model]

    #     response = requests.post(
    #         f"{base_url}/key/generate", headers=headers, json=key_payload
    #     )

    #     assert response.status_code == 200, (
    #         f"Failed to generate key with allowed model. "
    #         f"Status Code: {response.status_code}. Response: {response.text}"
    #     )

    #     # Verify the generated key only has access to allowed model
    #     generated_key = response.json()
    #     assert set(generated_key["models"]) == {
    #         allowed_model
    #     }, "Generated key should only have access to allowed model"

    #     print("\nSuccessfully verified model access restrictions for key generation")

    def test_budget_escalation_attempt(self):
        """Test that a user cannot create a key with a higher budget than they have"""
        # Create a test user with zero budget
        test_user = self.create_test_user(
            max_budget=0,
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        )

        # Verify initial user has zero budget
        assert test_user["max_budget"] == 0, "Initial user should have zero budget"

        # Prepare headers using the test user's key
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {test_user['key']}",
        }

        # Try to generate a key with a higher budget
        key_payload = {
            "user_id": test_user["user_id"],
            "duration": "7d",
            "key_alias": f"test_key_{uuid.uuid4()}",
            "max_budget": 100,  # Attempting to get higher budget
            "budget_duration": "7d",
            "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0"],
            "metadata": {"purpose": "testing_budget_escalation", "environment": "test"},
        }

        # Make request to generate new key
        response = requests.post(
            f"{base_url}/key/generate", headers=headers, json=key_payload
        )

        print("\nKey Generation Response Details:")
        print(f"Status Code: {response.status_code}")
        print("\nResponse Content:")
        try:
            formatted_json = json.dumps(response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(response.text)

        # Even if key generation somehow succeeds, verify the API calls still fail
        if response.status_code == 200:
            print(
                "\nWarning: Key generation succeeded when it should have failed. Testing API access..."
            )
            generated_key = response.json()

            client = OpenAI(
                base_url=base_url,
                api_key=generated_key["key"],
            )

            # Try multiple API calls to verify budget enforcement
            for i in range(3):
                print(f"\nAttempting API call {i+1}...")
                try:
                    content, session_id = get_completion(
                        client,
                        "This call should fail due to zero budget.",
                        model="anthropic.claude-3-5-sonnet-20240620-v1:0",
                    )
                    print(
                        f"Warning: API call {i+1} succeeded when it should have failed"
                    )
                    print(f"Content: {content}")
                    print(f"Session ID: {session_id}")
                except OpenAIError as e:
                    print(f"API call {i+1} failed as expected with error: {str(e)}")
                    error_message = str(e).lower()
                    assert any(
                        keyword in error_message
                        for keyword in ["budget", "spend", "limit"]
                    ), f"Expected budget-related error, got: {error_message}"
        else:
            # Verify key generation was rejected with appropriate error
            assert (
                response.status_code == 400
            ), "Request should have been rejected with 400 status code"
            error_message = response.json().get("error", {}).get("message", "").lower()
            assert any(
                keyword in error_message
                for keyword in ["budget", "limit", "permission"]
            ), f"Expected budget-related error, got: {error_message}"

        print("\nSuccessfully verified budget escalation prevention")

    # Broken right now: https://github.com/BerriAI/litellm/issues/8029
    def test_rate_limits_timing_comparison(self):
        """Compare processing times of parallel requests between original and generated keys"""
        # Create a test user with strict rate limits
        test_user = self.create_test_user(
            max_budget=100,  # Sufficient budget for multiple calls
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
            rpm_limit=1,  # Only 2 requests per minute allowed
            tpm_limit=1,  # Limited tokens per minute
            max_parallel_requests=1,  # Limit parallel requests
        )

        # Try to generate a key with higher limits
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {test_user['key']}",
        }

        key_payload = {
            "user_id": test_user["user_id"],
            "duration": "7d",
            "key_alias": f"test_key_{uuid.uuid4()}",
            "rpm_limit": 1000,  # Attempting to get higher RPM
            "tpm_limit": 100000,  # Attempting to get higher TPM
            "max_parallel_requests": 10,  # Attempting to get higher parallel limit
            "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0"],
            "metadata": {
                "purpose": "testing_rate_limit_escalation",
                "environment": "test",
            },
        }

        print("\nGenerating key with attempted higher rate limits...")
        response = requests.post(
            f"{base_url}/key/generate", headers=headers, json=key_payload
        )

        print("\nKey Generation Response:")
        print(f"Status Code: {response.status_code}")
        try:
            formatted_json = json.dumps(response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(response.text)

        # Initialize clients for both keys
        original_client = OpenAI(
            base_url=base_url,
            api_key=test_user["key"],
        )

        generated_client = OpenAI(
            base_url=base_url,
            api_key=response.json()["key"],
        )

        def make_timed_requests(
            client: OpenAI, num_requests: int = 14
        ) -> List[Dict[str, Any]]:
            """Make parallel requests and record timing information"""

            def single_request(i: int) -> Dict[str, Any]:
                start_time = time.time()
                try:
                    content, session_id = get_completion(
                        client,
                        "This is a test message for parallel request processing.",
                        model="anthropic.claude-3-5-sonnet-20240620-v1:0",
                    )
                    end_time = time.time()
                    print(f"duration: {end_time - start_time}")
                    return {
                        "request_num": i,
                        "status": "success",
                        "duration": end_time - start_time,
                        "content": content,
                        "session_id": session_id,
                        "error": None,
                    }
                except Exception as e:
                    end_time = time.time()
                    return {
                        "request_num": i,
                        "status": "error",
                        "duration": end_time - start_time,
                        "content": None,
                        "session_id": None,
                        "error": str(e),
                    }

            with ThreadPoolExecutor(max_workers=num_requests) as executor:
                futures = [
                    executor.submit(single_request, i) for i in range(num_requests)
                ]
                return [f.result() for f in futures]

        # Test original key
        # print("\nTesting original key with rate limits...")
        # original_results = make_timed_requests(original_client)

        # Small delay between tests
        # time.sleep(5)

        # Test generated key
        print("\nTesting generated key...")
        generated_results = make_timed_requests(generated_client)

        # Analyze and compare results
        def analyze_results(results: List[Dict[str, Any]], key_type: str):
            successful = [r for r in results if r["status"] == "success"]
            failed = [r for r in results if r["status"] == "error"]
            total_duration = sum(r["duration"] for r in results)
            avg_duration = total_duration / len(results) if results else 0

            print(f"\n{key_type} Key Results:")
            print(f"Total requests: {len(results)}")
            print(f"Successful requests: {len(successful)}")
            print(f"Failed requests: {len(failed)}")
            print(f"Total duration: {total_duration:.2f} seconds")
            print(f"Average duration: {avg_duration:.2f} seconds")
            print("\nIndividual request timings:")
            for r in results:
                status = (
                    "Success" if r["status"] == "success" else f"Error: {r['error']}"
                )
                print(f"Request {r['request_num']}: {r['duration']:.2f}s - {status}")

            return {
                "total_requests": len(results),
                "successful": len(successful),
                "failed": len(failed),
                "total_duration": total_duration,
                "avg_duration": avg_duration,
            }

        # original_stats = analyze_results(original_results, "Original")
        generated_stats = analyze_results(generated_results, "Generated")

        # Compare the results
        print("\nComparison:")
        # print(
        #     f"Original key average request time: {original_stats['avg_duration']:.2f}s"
        # )
        print(
            f"Generated key average request time: {generated_stats['avg_duration']:.2f}s"
        )
        # print(f"Original key successful requests: {original_stats['successful']}")
        print(f"Generated key successful requests: {generated_stats['successful']}")

        # Verify rate limits were effectively the same
        # timing_difference = abs(
        #     original_stats["avg_duration"] - generated_stats["avg_duration"]
        # )
        # success_difference = abs(
        #     original_stats["successful"] - generated_stats["successful"]
        # )

        # print(f"\nTiming difference: {timing_difference:.2f}s")
        # print(f"Success count difference: {success_difference}")

        # These assertions verify that the generated key doesn't perform significantly better
        # assert success_difference <= 1, "Keys should have similar success rates"
        # Allow for some timing variance but catch significant differences
        # assert timing_difference < 2.0, "Keys should have similar processing times"

    # def test_rate_limits_timing_comparison(self):
    #     """Compare processing times between two users - one with original key and another with generated key"""
    #     # Create first test user with strict rate limits
    #     user1 = self.create_test_user(
    #         max_budget=100,
    #         budget_duration="30d",
    #         models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
    #         rpm_limit=1,
    #         tpm_limit=10000,
    #         max_parallel_requests=1,
    #     )

    #     # Create second test user with same strict rate limits
    #     user2 = self.create_test_user(
    #         max_budget=100,
    #         budget_duration="30d",
    #         models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
    #         rpm_limit=1,
    #         tpm_limit=10000,
    #         max_parallel_requests=1,
    #     )

    #     # Try to generate a key with higher limits for user2
    #     headers = {
    #         "Content-Type": "application/json",
    #         "Authorization": f"Bearer {user2['key']}",
    #     }

    #     key_payload = {
    #         "user_id": user2["user_id"],
    #         "duration": "7d",
    #         "key_alias": f"test_key_{uuid.uuid4()}",
    #         "rpm_limit": 1000,  # Attempting to get higher RPM
    #         "tpm_limit": 100000,  # Attempting to get higher TPM
    #         "max_parallel_requests": 10,  # Attempting to get higher parallel limit
    #         "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0"],
    #         "metadata": {
    #             "purpose": "testing_rate_limit_escalation",
    #             "environment": "test",
    #         },
    #     }

    #     print("\nGenerating key with attempted higher rate limits for user2...")
    #     response = requests.post(
    #         f"{base_url}/key/generate", headers=headers, json=key_payload
    #     )

    #     print("\nKey Generation Response:")
    #     print(f"Status Code: {response.status_code}")
    #     try:
    #         formatted_json = json.dumps(response.json(), indent=2)
    #         print(formatted_json)
    #     except json.JSONDecodeError:
    #         print(response.text)

    #     # Initialize clients for both users
    #     user1_client = OpenAI(
    #         base_url=base_url,
    #         api_key=user1["key"],
    #     )

    #     user2_generated_client = OpenAI(
    #         base_url=base_url,
    #         api_key=response.json()["key"],
    #     )

    #     def make_timed_requests(
    #         client: OpenAI, num_requests: int = 2
    #     ) -> List[Dict[str, Any]]:
    #         """Make parallel requests and record timing information"""

    #         def single_request(i: int) -> Dict[str, Any]:
    #             start_time = time.time()
    #             try:
    #                 content, session_id = get_completion(
    #                     client,
    #                     "This is a test message for parallel request processing.",
    #                     model="anthropic.claude-3-5-sonnet-20240620-v1:0",
    #                 )
    #                 end_time = time.time()
    #                 print(f"duration: {end_time - start_time}")
    #                 return {
    #                     "request_num": i,
    #                     "status": "success",
    #                     "duration": end_time - start_time,
    #                     "content": content,
    #                     "session_id": session_id,
    #                     "error": None,
    #                 }
    #             except Exception as e:
    #                 end_time = time.time()
    #                 return {
    #                     "request_num": i,
    #                     "status": "error",
    #                     "duration": end_time - start_time,
    #                     "content": None,
    #                     "session_id": None,
    #                     "error": str(e),
    #                 }

    #         with ThreadPoolExecutor(max_workers=num_requests) as executor:
    #             futures = [
    #                 executor.submit(single_request, i) for i in range(num_requests)
    #             ]
    #             return [f.result() for f in futures]

    #     # Test user1's original key
    #     print("\nTesting user1's original key with rate limits...")
    #     user1_results = make_timed_requests(user1_client)

    #     # Small delay between tests
    #     time.sleep(5)

    #     # Test user2's generated key
    #     print("\nTesting user2's generated key...")
    #     user2_generated_results = make_timed_requests(user2_generated_client)

    #     # Analyze and compare results
    #     def analyze_results(results: List[Dict[str, Any]], key_type: str):
    #         successful = [r for r in results if r["status"] == "success"]
    #         failed = [r for r in results if r["status"] == "error"]
    #         total_duration = sum(r["duration"] for r in results)
    #         avg_duration = total_duration / len(results) if results else 0

    #         print(f"\n{key_type} Key Results:")
    #         print(f"Total requests: {len(results)}")
    #         print(f"Successful requests: {len(successful)}")
    #         print(f"Failed requests: {len(failed)}")
    #         print(f"Total duration: {total_duration:.2f} seconds")
    #         print(f"Average duration: {avg_duration:.2f} seconds")
    #         print("\nIndividual request timings:")
    #         for r in results:
    #             status = (
    #                 "Success" if r["status"] == "success" else f"Error: {r['error']}"
    #             )
    #             print(f"Request {r['request_num']}: {r['duration']:.2f}s - {status}")

    #         return {
    #             "total_requests": len(results),
    #             "successful": len(successful),
    #             "failed": len(failed),
    #             "total_duration": total_duration,
    #             "avg_duration": avg_duration,
    #         }

    #     user1_stats = analyze_results(user1_results, "User1 Original")
    #     user2_stats = analyze_results(user2_generated_results, "User2 Generated")

    #     # Compare the results
    #     print("\nComparison:")
    #     print(
    #         f"User1 original key average request time: {user1_stats['avg_duration']:.2f}s"
    #     )
    #     print(
    #         f"User2 generated key average request time: {user2_stats['avg_duration']:.2f}s"
    #     )
    #     print(f"User1 original key successful requests: {user1_stats['successful']}")
    #     print(f"User2 generated key successful requests: {user2_stats['successful']}")

    #     # Calculate differences
    #     timing_difference = abs(
    #         user1_stats["avg_duration"] - user2_stats["avg_duration"]
    #     )
    #     success_difference = abs(user1_stats["successful"] - user2_stats["successful"])

    #     print(f"\nTiming difference: {timing_difference:.2f}s")
    #     print(f"Success count difference: {success_difference}")

    #     # Verify that the keys perform similarly
    #     assert success_difference <= 1, "Keys should have similar success rates"
    #     assert timing_difference < 2.0, "Keys should have similar processing times"

    def test_key_user_isolation(self):
        """Test that a user cannot generate keys for another user"""
        # Create two test users
        user1 = self.create_test_user(
            max_budget=100,
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        )

        user2 = self.create_test_user(
            max_budget=100,
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        )

        print("\nCreated two test users:")
        print(f"User 1 ID: {user1['user_id']}")
        print(f"User 2 ID: {user2['user_id']}")

        # Try to generate a key for user2 using user1's key
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {user1['key']}",
        }

        key_payload = {
            "user_id": user2["user_id"],  # Attempting to create key for user2
            "duration": "7d",
            "key_alias": f"test_key_{uuid.uuid4()}",
            "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0"],
            "metadata": {"purpose": "testing_user_isolation", "environment": "test"},
        }

        print("\nAttempting to generate key for user2 using user1's key...")
        response = requests.post(
            f"{base_url}/key/generate", headers=headers, json=key_payload
        )

        print("\nKey Generation Response Details:")
        print(f"Status Code: {response.status_code}")
        print("\nResponse Content:")
        try:
            formatted_json = json.dumps(response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(response.text)

        # Verify request was rejected
        assert (
            response.status_code == 400 or response.status_code == 403
        ), "Request should have been rejected with 400 status code"

        # Verify error message indicates unauthorized user access
        error_message = response.json().get("error", {}).get("message", "").lower()
        assert any(
            keyword in error_message
            for keyword in ["unauthorized", "permission", "access", "user"]
        ), f"Expected unauthorized user error, got: {error_message}"

        # Verify user2 can still generate their own keys
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {user2['key']}",
        }

        key_payload = {
            "user_id": user2["user_id"],
            "duration": "7d",
            "key_alias": f"test_key_{uuid.uuid4()}",
            "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0"],
            "metadata": {"purpose": "testing_user_isolation", "environment": "test"},
        }

        print("\nVerifying user2 can still generate their own keys...")
        response = requests.post(
            f"{base_url}/key/generate", headers=headers, json=key_payload
        )

        assert response.status_code == 200, (
            f"User2 should be able to generate their own keys. "
            f"Status Code: {response.status_code}. Response: {response.text}"
        )

        # Additional verification: Try to use the (failed) key if it was somehow generated
        if response.status_code == 200:
            # Initialize client with the generated key
            client = OpenAI(
                base_url=base_url,
                api_key=response.json()["key"],
            )

            try:
                content, session_id = get_completion(
                    client,
                    "Test message using generated key.",
                    model="anthropic.claude-3-5-sonnet-20240620-v1:0",
                )
                print("\nVerified that user2's self-generated key works:")
                print(f"Content: {content[:100]}...")

            except Exception as e:
                pytest.fail(
                    f"User2's self-generated key should work but failed: {str(e)}"
                )

        print("\nSuccessfully verified user isolation in key generation")

    def test_key_deletion_isolation(self):
        """Test that a user cannot delete another user's keys"""
        # Create two test users
        user1 = self.create_test_user(
            max_budget=100,
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        )

        user2 = self.create_test_user(
            max_budget=100,
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        )

        print("\nCreated two test users:")
        print(f"User 1 ID: {user1['user_id']}")
        print(f"User 2 ID: {user2['user_id']}")
        print(f"User 2 Key: {user2['key']}")

        # Generate an additional key for user2 to ensure they have multiple keys
        user2_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {user2['key']}",
        }

        additional_key_payload = {
            "user_id": user2["user_id"],
            "duration": "7d",
            "key_alias": f"test_key_{uuid.uuid4()}",
            "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        }

        print("\nGenerating additional key for user2...")
        additional_key_response = requests.post(
            f"{base_url}/key/generate",
            headers=user2_headers,
            json=additional_key_payload,
        )

        assert (
            additional_key_response.status_code == 200
        ), "Failed to generate additional key for user2"
        user2_additional_key = additional_key_response.json()["key"]

        # Try to delete user2's keys using user1's authorization
        user1_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {user1['key']}",
        }

        deletion_payload = {"keys": [user2["key"], user2_additional_key]}

        print("\nAttempting to delete user2's keys using user1's authorization...")
        response = requests.post(
            f"{base_url}/key/delete", headers=user1_headers, json=deletion_payload
        )

        print("\nDeletion Attempt Response Details:")
        print(f"Status Code: {response.status_code}")
        print("\nResponse Content:")
        try:
            formatted_json = json.dumps(response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(response.text)

        # Verify deletion attempt was rejected
        assert (
            response.status_code == 400 or response.status_code == 500
        ), "Request should have been rejected with 400 status code"

        # Verify error message indicates unauthorized access
        error_message = response.json().get("error", {}).get("message", "").lower()
        assert any(
            keyword in error_message
            for keyword in ["unauthorized", "permission", "access", "failed"]
        ), f"Expected unauthorized access error, got: {error_message}"

        # Verify user2's keys are still valid by trying to use them
        def verify_key(key: str, key_type: str):
            client = OpenAI(
                base_url=base_url,
                api_key=key,
            )

            try:
                content, session_id = get_completion(
                    client,
                    f"Test message using {key_type}.",
                    model="anthropic.claude-3-5-sonnet-20240620-v1:0",
                )
                print(f"\nVerified {key_type} still works:")
                print(f"Content: {content[:100]}...")
                return True
            except Exception as e:
                print(f"\nError using {key_type}: {str(e)}")
                return False

        # Verify both of user2's keys still work
        original_key_valid = verify_key(user2["key"], "user2's original key")
        additional_key_valid = verify_key(
            user2_additional_key, "user2's additional key"
        )

        assert original_key_valid, "User2's original key should still be valid"
        assert additional_key_valid, "User2's additional key should still be valid"

        # Verify user2 can delete their own keys
        print("\nVerifying user2 can delete their additional key...")
        user2_deletion_response = requests.post(
            f"{base_url}/key/delete",
            headers=user2_headers,
            json={"keys": [user2_additional_key]},
        )

        assert user2_deletion_response.status_code == 200, (
            f"User2 should be able to delete their own key. "
            f"Status Code: {user2_deletion_response.status_code}. "
            f"Response: {user2_deletion_response.text}"
        )

        # Verify the deleted key no longer works
        deleted_key_valid = verify_key(user2_additional_key, "user2's deleted key")
        assert not deleted_key_valid, "Deleted key should no longer work"

        # Verify user2's original key still works
        assert verify_key(
            user2["key"], "user2's original key after deletion"
        ), "User2's original key should still work after deleting additional key"

        print("\nSuccessfully verified key deletion isolation")

    # Broken right now: https://github.com/BerriAI/litellm/issues/8031
    def test_key_update_user_isolation(self):
        """Test that a user cannot update their key to belong to another user"""
        # Create two test users
        user1 = self.create_test_user(
            max_budget=100,
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        )

        user2 = self.create_test_user(
            max_budget=100,
            budget_duration="30d",
            models=["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        )

        print("\nCreated two test users:")
        print(f"User 1 ID: {user1['user_id']}")
        print(f"User 2 ID: {user2['user_id']}")

        # Create an additional key for user1 that we'll try to update
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {user1['key']}",
        }

        key_payload = {
            "user_id": user1["user_id"],
            "duration": "7d",
            "key_alias": f"test_key_{uuid.uuid4()}",
            "models": ["anthropic.claude-3-5-sonnet-20240620-v1:0"],
        }

        print("\nGenerating additional key for user1...")
        key_response = requests.post(
            f"{base_url}/key/generate", headers=headers, json=key_payload
        )

        assert (
            key_response.status_code == 200
        ), "Failed to generate additional key for user1"
        user1_additional_key = key_response.json()

        print(f"\nGenerated key details:")
        print(json.dumps(user1_additional_key, indent=2))

        # Try to update the key to belong to user2
        update_payload = {
            "key": user1_additional_key["key"],
            "user_id": user2["user_id"],  # Attempting to change ownership to user2
            "metadata": {"purpose": "testing_user_isolation", "environment": "test"},
        }

        print("\nAttempting to update key ownership to user2...")
        update_response = requests.post(
            f"{base_url}/key/update", headers=headers, json=update_payload
        )

        print("\nUpdate Attempt Response Details:")
        print(f"Status Code: {update_response.status_code}")
        print("\nResponse Content:")
        try:
            formatted_json = json.dumps(update_response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(update_response.text)

        # Verify update attempt was rejected
        assert (
            update_response.status_code == 400
        ), "Request should have been rejected with 400 status code"

        # Verify error message indicates unauthorized modification
        error_message = (
            update_response.json().get("error", {}).get("message", "").lower()
        )
        assert any(
            keyword in error_message
            for keyword in ["unauthorized", "permission", "access", "user"]
        ), f"Expected unauthorized modification error, got: {error_message}"

        # Verify the key still belongs to user1 by checking if user1 can use it
        client = OpenAI(
            base_url=base_url,
            api_key=user1_additional_key["key"],
        )

        try:
            content, session_id = get_completion(
                client,
                "Test message using user1's key.",
                model="anthropic.claude-3-5-sonnet-20240620-v1:0",
            )
            print("\nVerified key still works for user1:")
            print(f"Content: {content[:100]}...")
        except Exception as e:
            pytest.fail(f"Key should still work for user1 but failed: {str(e)}")

        # Verify user2 cannot use or update the key
        user2_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {user2['key']}",
        }

        print("\nAttempting to update key using user2's authorization...")
        user2_update_response = requests.post(
            f"{base_url}/key/update",
            headers=user2_headers,
            json={"key": user1_additional_key["key"], "metadata": {"test": "update"}},
        )

        assert (
            user2_update_response.status_code == 400
        ), "User2 should not be able to update user1's key"

        # Verify legitimate key updates still work for user1
        print("\nVerifying user1 can still update their own key...")
        legitimate_update = {
            "key": user1_additional_key["key"],
            "metadata": {"updated": "true", "purpose": "testing"},
        }

        legitimate_response = requests.post(
            f"{base_url}/key/update", headers=headers, json=legitimate_update
        )

        assert legitimate_response.status_code == 200, (
            f"User1 should be able to update their own key. "
            f"Status Code: {legitimate_response.status_code}. "
            f"Response: {legitimate_response.text}"
        )

        print("\nSuccessfully verified key update isolation")

    def test_team_user_restrictions(self):
        """Test that team restrictions (models, budgets) are properly applied to team members"""

        # First create a team with specific model restrictions
        allowed_models = ["anthropic.claude-3-5-sonnet-20240620-v1:0"]
        restricted_model = "anthropic.claude-3-haiku-20240307-v1:0"

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        }

        team_payload = {
            "team_alias": f"test_team_{uuid.uuid4()}",
            "max_budget": 0,  # Zero budget to ensure we hit the limit
            "budget_duration": "1mo",
            "models": allowed_models,
            "tpm_limit": 10000,
            "rpm_limit": 10,
        }

        print("\nCreating test team...")
        team_response = requests.post(
            f"{base_url}/team/new", headers=headers, json=team_payload
        )

        print("\nTeam Creation Response:")
        print(f"Status Code: {team_response.status_code}")
        try:
            formatted_json = json.dumps(team_response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(team_response.text)

        assert (
            team_response.status_code == 200
        ), f"Failed to create team. Response: {team_response.text}"
        team_data = team_response.json()

        # Create a test user with non-zero budget and assign to team directly
        test_user = self.create_test_user(
            max_budget=100,  # User has budget, but team budget should override
            budget_duration="1mo",
            teams=[
                team_data["team_id"]
            ],  # Directly assign user to team during creation
        )

        print(f"\nCreated test user: {test_user['user_id']}")

        # Initialize client with user's key
        client = OpenAI(
            base_url=base_url,
            api_key=test_user["key"],
        )

        print(f'test_user["key"] {test_user["key"]}')
        # Test access to allowed model
        try:
            content, session_id = get_completion(
                client,
                "This call should succeed with an allowed model.",
                model=allowed_models[0],
            )
            print(f"\nSuccessfully called allowed model: {allowed_models[0]}")
            print(f"Response content: {content}")
            print(f"Session ID: {session_id}")
        except Exception as e:
            pytest.fail(
                f"Call to allowed model should have succeeded but failed: {str(e)}"
            )

        # Test access to restricted model
        with pytest.raises(OpenAIError) as exc_info:
            content, session_id = get_completion(
                client,
                "This call should fail due to team model restriction.",
                model=restricted_model,
            )
            print(f"\nSuccessfully called allowed model: {restricted_model}")
            print(f"Response content: {content}")
            print(f"Session ID: {session_id}")

        # Verify error message indicates model access issue
        error_message = str(exc_info.value).lower()
        assert any(
            keyword in error_message
            for keyword in ["model", "access", "permission", "unauthorized"]
        ), f"Expected model access error, got: {error_message}"

        print(f"\nVerified model access restrictions are enforced")
        print(f"Error message for restricted model: {str(exc_info.value)}")

        # Test budget enforcement
        # With zero team budget, the second call should fail
        print("\nTesting budget enforcement (team budget = 0)...")

        # First call should succeed (spend == 0)
        try:
            content, session_id = get_completion(
                client,
                "First call should succeed with zero spend.",
                model=allowed_models[0],
            )
            print("\nFirst call succeeded as expected")
            print(f"Content: {content}")
            print(f"Session ID: {session_id}")
        except Exception as e:
            pytest.fail(f"First API call should have succeeded but failed: {str(e)}")

        # Second call should fail due to zero budget
        print("\nAttempting second call (should fail due to team budget = 0)...")

        with pytest.raises(OpenAIError) as exc_info:
            get_completion(
                client,
                "Second call should fail due to zero team budget.",
                model=allowed_models[0],
            )

        # Verify error message indicates budget issue
        error_message = str(exc_info.value).lower()
        assert any(
            keyword in error_message for keyword in ["budget", "spend", "limit"]
        ), f"Expected budget-related error, got: {error_message}"

        print(f"\nSecond call failed as expected with error: {error_message}")

    def test_team_user_restrictions_new_api_key(self):
        """Test that team restrictions (models, budgets) are properly applied to team members"""

        # First create a team with specific model restrictions
        allowed_models = ["anthropic.claude-3-5-sonnet-20240620-v1:0"]
        restricted_model = "anthropic.claude-3-haiku-20240307-v1:0"

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        }

        team_payload = {
            "team_alias": f"test_team_{uuid.uuid4()}",
            "max_budget": 0,  # Zero budget to ensure we hit the limit
            "budget_duration": "1mo",
            "models": allowed_models,
            "tpm_limit": 10000,
            "rpm_limit": 10,
        }

        print("\nCreating test team...")
        team_response = requests.post(
            f"{base_url}/team/new", headers=headers, json=team_payload
        )

        print("\nTeam Creation Response:")
        print(f"Status Code: {team_response.status_code}")
        try:
            formatted_json = json.dumps(team_response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(team_response.text)

        assert (
            team_response.status_code == 200
        ), f"Failed to create team. Response: {team_response.text}"
        team_data = team_response.json()

        # Create a test user with non-zero budget and assign to team directly
        test_user = self.create_test_user(
            max_budget=100,  # User has budget, but team budget should override
            budget_duration="1mo",
            teams=[
                team_data["team_id"]
            ],  # Directly assign user to team during creation
        )

        print(f"\nCreated test user: {test_user['user_id']}")

        # Generate a new key for the user
        key_headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {test_user['key']}",  # Use user's original key to generate new key
        }

        key_payload = {
            "user_id": test_user["user_id"],
            "key_alias": f"test_key_{uuid.uuid4()}",
        }

        print("\nGenerating new key for user...")
        key_response = requests.post(
            f"{base_url}/key/generate", headers=key_headers, json=key_payload
        )

        print("\nKey Generation Response:")
        print(f"Status Code: {key_response.status_code}")
        try:
            formatted_json = json.dumps(key_response.json(), indent=2)
            print(formatted_json)
        except json.JSONDecodeError:
            print(key_response.text)

        assert (
            key_response.status_code == 200
        ), f"Failed to generate key. Response: {key_response.text}"
        generated_key = key_response.json()

        # Initialize client with the newly generated key
        client = OpenAI(
            base_url=base_url,
            api_key=generated_key["key"],
        )

        print(f'Generated key: {generated_key["key"]}')

        # Test access to allowed model
        try:
            content, session_id = get_completion(
                client,
                "This call should succeed with an allowed model.",
                model=allowed_models[0],
            )
            print(f"\nSuccessfully called allowed model: {allowed_models[0]}")
            print(f"Response content: {content}")
            print(f"Session ID: {session_id}")
        except Exception as e:
            pytest.fail(
                f"Call to allowed model should have succeeded but failed: {str(e)}"
            )

        # Test access to restricted model
        with pytest.raises(OpenAIError) as exc_info:
            content, session_id = get_completion(
                client,
                "This call should fail due to team model restriction.",
                model=restricted_model,
            )
            print(f"\nSuccessfully called allowed model: {restricted_model}")
            print(f"Response content: {content}")
            print(f"Session ID: {session_id}")

        # Verify error message indicates model access issue
        error_message = str(exc_info.value).lower()
        assert any(
            keyword in error_message
            for keyword in ["model", "access", "permission", "unauthorized"]
        ), f"Expected model access error, got: {error_message}"

        print(f"\nVerified model access restrictions are enforced")
        print(f"Error message for restricted model: {str(exc_info.value)}")

        # Test budget enforcement
        # With zero team budget, the second call should fail
        print("\nTesting budget enforcement (team budget = 0)...")

        # First call should succeed (spend == 0)
        try:
            content, session_id = get_completion(
                client,
                "First call should succeed with zero spend.",
                model=allowed_models[0],
            )
            print("\nFirst call succeeded as expected")
            print(f"Content: {content}")
            print(f"Session ID: {session_id}")
        except Exception as e:
            pytest.fail(f"First API call should have succeeded but failed: {str(e)}")

        # Second call should fail due to zero budget
        print("\nAttempting second call (should fail due to team budget = 0)...")

        with pytest.raises(OpenAIError) as exc_info:
            get_completion(
                client,
                "Second call should fail due to zero team budget.",
                model=allowed_models[0],
            )

        # Verify error message indicates budget issue
        error_message = str(exc_info.value).lower()
        assert any(
            keyword in error_message for keyword in ["budget", "spend", "limit"]
        ), f"Expected budget-related error, got: {error_message}"

        print(f"\nSecond call failed as expected with error: {error_message}")
