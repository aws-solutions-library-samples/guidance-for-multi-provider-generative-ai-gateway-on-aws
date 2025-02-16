import boto3
import os
from botocore.client import Config
from botocore import UNSIGNED
from typing import Generator, Dict, Any, Optional


global_session_id: Optional[str] = None


def create_bedrock_client():
    """
    Creates a Bedrock client with custom endpoint and authorization header.
    Uses environment variables for configuration.

    Required environment variables:
    - API_ENDPOINT: Custom Bedrock endpoint URL
    - API_KEY: Authorization bearer token
    - AWS_REGION: AWS region

    Returns:
        boto3.client: Configured Bedrock client
    """
    endpoint = os.getenv("API_ENDPOINT")
    api_key = os.getenv("API_KEY")
    region = os.getenv("AWS_REGION")

    if not all([endpoint, api_key, region]):
        raise ValueError(
            "Missing required environment variables: API_ENDPOINT, API_KEY, AWS_REGION"
        )

    # Initialize session and configure client
    session = boto3.Session()
    client_config = Config(
        signature_version=UNSIGNED,  # Disable SigV4 signing
        retries={"max_attempts": 10, "mode": "standard"},
    )

    # Create the Bedrock client
    client = session.client(
        "bedrock-runtime",
        endpoint_url=endpoint,
        config=client_config,
        region_name=region,
    )

    # Define authorization header handler
    def add_authorization_header(request, **kwargs):
        request.headers["Authorization"] = f"Bearer {api_key}"

    # Register the event handler
    client.meta.events.register("request-created.*", add_authorization_header)

    return client


def extract_session_id(response) -> Optional[str]:
    """
    Extracts the x-session-id from the response headers.

    Args:
        response: The raw response object from the Bedrock API

    Returns:
        str: The session ID if found, None otherwise
    """
    try:
        # Access the response metadata which contains the headers
        headers = response["ResponseMetadata"]["HTTPHeaders"]
        print(f"headers: {headers}")
        session_id = headers.get("x-session-id")
        print(f"session_id: {session_id}")
        return session_id
    except (KeyError, AttributeError):
        print("Warning: Could not extract x-session-id from response headers")
        return None


def send_message_stream(
    client,
    message: str,
    model_id: str = "anthropic.claude-3-haiku-20240307-v1:0",
    max_tokens: int = 1000,
    temperature: float = 0.7,
) -> Generator[Dict[str, Any], None, None]:
    """
    Sends a message to the Bedrock Converse API with streaming response.

    Args:
        client: Configured Bedrock client
        message (str): Message to send
        model_id (str): ID of the model to use
        max_tokens (int): Maximum number of tokens to generate
        temperature (float): Temperature for response generation

    Yields:
        dict: Streaming response events
    """

    global global_session_id

    try:
        if global_session_id:
            response = client.converse_stream(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": message}]}],
                inferenceConfig={
                    "maxTokens": max_tokens,
                    "temperature": temperature,
                },
                additionalModelRequestFields={"session_id": global_session_id},
            )
        else:
            response = client.converse_stream(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": message}]}],
                inferenceConfig={
                    "maxTokens": max_tokens,
                    "temperature": temperature,
                },
                additionalModelRequestFields={"enable_history": True},
            )
        global_session_id = extract_session_id(response)
        if global_session_id:
            print(f"global_session_id: {global_session_id}")
        print(f"response: {response}")
        print(f"response['stream']: {response["stream"]}")

        # Process the streaming response
        for event in response["stream"]:
            yield event

    except Exception as e:
        print(f"Error in streaming request: {str(e)}")
        raise


def process_stream_response(event: Dict[str, Any]) -> str:
    """
    Processes a streaming response event and extracts the text content if present.

    Args:
        event (dict): Streaming response event

    Returns:
        str: Extracted text content or empty string
    """
    if "contentBlockDelta" in event:
        delta = event["contentBlockDelta"].get("delta", {})
        if "text" in delta:
            return delta["text"]
    return ""


def send_message_stream_wrapper(client, message):
    try:

        # Accumulate the response

        # Process the streaming response
        for event in send_message_stream(client, message):
            print(f"event: {event}")
            # Handle different event types
            if "internalServerException" in event:
                raise Exception(
                    f"Internal server error: {event['internalServerException']}"
                )
            elif "modelStreamErrorException" in event:
                raise Exception(
                    f"Model stream error: {event['modelStreamErrorException']}"
                )
            elif "validationException" in event:
                raise Exception(f"Validation error: {event['validationException']}")
            elif "throttlingException" in event:
                raise Exception(f"Throttling error: {event['throttlingException']}")
            # Handle metadata and stop events
            if "messageStop" in event:
                print("\n\nStream finished.")
                print(f"Stop reason: {event['messageStop'].get('stopReason')}")
            elif "metadata" in event:
                usage = event["metadata"].get("usage", {})
                if usage:
                    print(f"\nToken usage: {usage}")

    except Exception as e:
        print(f"Error in main: {str(e)}")


def main():
    # Create the client
    client = create_bedrock_client()

    # Example of using streaming response
    print("Sending streaming request...")
    message = "tell me a short story."
    send_message_stream_wrapper(client=client, message=message)
    message2 = "What did I last say to you?"
    send_message_stream_wrapper(client=client, message=message2)


if __name__ == "__main__":
    main()
