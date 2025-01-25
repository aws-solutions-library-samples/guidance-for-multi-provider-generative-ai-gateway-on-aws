import pytest
import boto3
import os
from botocore.config import Config
from botocore.exceptions import ClientError
from typing import AsyncGenerator, Dict, Any, Tuple
from dotenv import load_dotenv
from botocore import UNSIGNED
from typing import Generator, Dict, Any, Tuple

load_dotenv()


def create_bedrock_client():
    endpoint = os.getenv("API_ENDPOINT") + "/bedrock"
    api_key = os.getenv("API_KEY")

    if not all([endpoint, api_key]):
        raise ValueError(
            "Missing required environment variables: API_ENDPOINT, API_KEY"
        )

    session = boto3.Session()
    client_config = Config(
        signature_version=UNSIGNED,  # Disable SigV4 signing
    )

    client = session.client(
        "bedrock-runtime",
        endpoint_url=endpoint,
        config=client_config,
    )

    def add_authorization_header(request, **kwargs):
        request.headers["Authorization"] = f"Bearer {api_key}"

    client.meta.events.register("request-created.*", add_authorization_header)
    return client


# Initialize global variables
client = create_bedrock_client()
model_id = os.getenv("MODEL_ID", "anthropic.claude-3-5-sonnet-20241022-v2:0")
managed_prompt_arn = os.getenv("MANAGED_PROMPT_ARN")
managed_prompt_variable_name = os.getenv("MANAGED_PROMPT_VARIABLE_NAME")
managed_prompt_variable_value = os.getenv("MANAGED_PROMPT_VARIABLE_VALUE")

small_prompt = "Tell me a one sentence story."
small_prompt_follow_up = "What did I last ask you?"
large_prompt = "Hello" * 10000


def get_completion(
    prompt: str,
    model_id: str = model_id,
    additional_fields: Dict[str, Any] = None,
    prompt_variables: Dict[str, Dict[str, str]] = None,
) -> Tuple[str, str]:
    """
    Gets a complete response from the API in a single request.
    Returns a tuple of (content, session_id).
    """
    if additional_fields is None:
        additional_fields = {}

    kwargs = {"modelId": model_id, "additionalModelRequestFields": additional_fields}

    if prompt_variables:
        kwargs["promptVariables"] = prompt_variables

    if prompt:  # Only add messages if there's a prompt
        kwargs["messages"] = [{"role": "user", "content": [{"text": prompt}]}]

    response = client.converse(**kwargs)

    session_id = response["ResponseMetadata"]["HTTPHeaders"].get("x-session-id")
    content = response["output"]["message"]["content"][0]["text"]
    return content, session_id


def stream_completion(
    prompt: str,
    model_id: str = model_id,
    additional_fields: Dict[str, Any] = None,
    prompt_variables: Dict[str, Dict[str, str]] = None,
) -> Generator[Tuple[str, str], None, None]:
    """
    Streams completion responses from the API.
    Yields tuples of (content, session_id).
    """
    if additional_fields is None:
        additional_fields = {}

    kwargs = {"modelId": model_id, "additionalModelRequestFields": additional_fields}

    if prompt_variables:
        kwargs["promptVariables"] = prompt_variables

    if prompt:  # Only add messages if there's a prompt
        kwargs["messages"] = [{"role": "user", "content": [{"text": prompt}]}]

    response = client.converse_stream(**kwargs)

    session_id = response["ResponseMetadata"]["HTTPHeaders"].get("x-session-id")
    event_stream = response["stream"]

    for event in event_stream:
        # Handle content block delta events
        if "contentBlockDelta" in event:
            delta = event["contentBlockDelta"]["delta"].get("text", "")
            yield delta, session_id


def test_bedrock_chat():
    content, session_id = get_completion(small_prompt)
    assert content is not None and content.strip()
    assert session_id is not None and session_id.strip()
    print(f"test_bedrock_chat response content: {content} session_id: {session_id}")


def test_bedrock_chat_streaming():
    session_id = None
    text_chunks = []
    for text_chunk, chunk_session_id in stream_completion(small_prompt):
        if chunk_session_id and not session_id:
            session_id = chunk_session_id
            print(f"\nReceived session ID: {session_id}")
        text_chunks.append(text_chunk)
        print(text_chunk, end="", flush=True)
    print("\n")

    assert session_id is not None and session_id.strip()
    assert text_chunks, "text_chunks should not be empty"
    assert all(
        text_chunk is not None for text_chunk in text_chunks
    ), "All text_chunks should be non null"


def test_bedrock_chat_history():
    print("First request:", flush=True)
    response_content_1, session_id_1 = get_completion(small_prompt)
    assert response_content_1 is not None and response_content_1.strip()
    assert session_id_1 is not None and session_id_1.strip()
    print(f"Content: {response_content_1}")
    print(f"Session ID: {session_id_1}\n")

    print("\nSecond request (with session_id):", flush=True)
    response_content_2, session_id_2 = get_completion(
        small_prompt_follow_up, additional_fields={"session_id": session_id_1}
    )
    print(f"Content: {response_content_2}")
    print(f"Session ID: {session_id_2}\n")
    assert response_content_2 is not None and response_content_2.strip()
    assert session_id_2 is not None and session_id_2.strip()
    assert session_id_1 == session_id_2


def test_bedrock_chat_streaming_history():
    session_id_1 = None
    text_chunks = []
    print("First request:", flush=True)
    for text_chunk, chunk_session_id in stream_completion(small_prompt):
        if chunk_session_id and not session_id_1:
            session_id_1 = chunk_session_id
            print(f"\nReceived session ID: {session_id_1}")
        text_chunks.append(text_chunk)
        print(f"text_chunk: {text_chunk}", end="", flush=True)
    print("\n")

    assert session_id_1 is not None and session_id_1.strip()
    assert text_chunks, "text_chunks should not be empty"
    assert all(
        text_chunk is not None for text_chunk in text_chunks
    ), "All text_chunks should be non null"

    session_id_2 = None
    text_chunks_2 = []
    print("\nSecond request (with session_id):", flush=True)
    for text_chunk, chunk_session_id in stream_completion(
        small_prompt_follow_up, additional_fields={"session_id": session_id_1}
    ):
        if chunk_session_id and not session_id_2:
            session_id_2 = chunk_session_id
            print(f"\nReceived session ID: {session_id_2}")
        text_chunks_2.append(text_chunk)
        print(f"text_chunk: {text_chunk}", end="", flush=True)
    print("\n")

    assert session_id_2 is not None and session_id_2.strip()
    assert text_chunks_2, "text_chunks_2 should not be empty"
    assert all(
        text_chunk is not None for text_chunk in text_chunks_2
    ), "All text_chunks_2 should be non null"
    assert session_id_1 == session_id_2


def test_bedrock_managed_prompt():
    """
    Tests the Bedrock managed prompt functionality with non-streaming response.
    """
    print("Testing Bedrock managed prompt:", flush=True)

    response_content, session_id = get_completion(
        "",  # Empty prompt as it won't be used
        model_id=managed_prompt_arn,
        prompt_variables={
            managed_prompt_variable_name: {"text": managed_prompt_variable_value},
        },
    )

    assert response_content is not None and response_content.strip()
    assert session_id is not None and session_id.strip()
    print(f"Content: {response_content}")
    print(f"Session ID: {session_id}\n")


def test_bedrock_managed_prompt_streaming():
    """
    Tests the Bedrock managed prompt functionality with streaming response.
    """
    print("Testing Bedrock managed prompt with streaming:", flush=True)

    session_id = None
    text_chunks = []

    for text_chunk, chunk_session_id in stream_completion(
        "",  # Empty prompt as it won't be used
        model_id=managed_prompt_arn,
        prompt_variables={
            managed_prompt_variable_name: {"text": managed_prompt_variable_value},
        },
    ):
        if chunk_session_id and not session_id:
            session_id = chunk_session_id
            print(f"\nReceived session ID: {session_id}")
        text_chunks.append(text_chunk)
        print(text_chunk, end="", flush=True)
    print("\n")

    assert session_id is not None and session_id.strip()
    assert text_chunks, "text_chunks should not be empty"
    assert all(
        text_chunk is not None for text_chunk in text_chunks
    ), "All text_chunks should be non null"


def test_large_prompt():
    content, session_id = get_completion(large_prompt)
    assert content is not None and content.strip()
    assert session_id is not None and session_id.strip()
    print(f"test_bedrock_chat response content: {content} session_id: {session_id}")


def test_invalid_api_key():
    """
    Tests that the API properly handles invalid API keys with appropriate error messages.
    """
    print("Testing invalid API key handling:", flush=True)

    # Create a new client with an invalid API key
    invalid_client = create_bedrock_client()

    # Override the event handler to use an invalid API key
    def add_invalid_authorization_header(request, **kwargs):
        request.headers["Authorization"] = "Bearer sk-invalid_key_12345"

    invalid_client.meta.events.register(
        "request-created.*", add_invalid_authorization_header
    )

    # Attempt to make a request with the invalid client
    with pytest.raises(ClientError) as exc_info:
        response = invalid_client.converse(
            modelId=model_id,
            messages=[{"role": "user", "content": [{"text": small_prompt}]}],
        )

    # Verify the error message contains authentication-related information
    error_message = str(exc_info.value).lower()
    print(f"Received error message: {error_message}")

    # Assert that the error message contains expected authentication-related terms
    assert any(
        term in error_message
        for term in ["auth", "authentication", "invalid", "key", "unauthorized"]
    ), "Error message should indicate authentication failure"
