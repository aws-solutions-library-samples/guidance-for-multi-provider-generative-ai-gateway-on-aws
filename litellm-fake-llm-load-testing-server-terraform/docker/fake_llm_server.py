from fastapi import FastAPI, Request, status
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.security import OAuth2PasswordBearer
from fastapi.middleware.cors import CORSMiddleware
from fastapi import HTTPException
from typing import Optional
from slowapi import Limiter
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
import asyncio
import random
import json
import socket
import uvicorn


class ProxyException(Exception):
    # NOTE: DO NOT MODIFY THIS
    # This is used to map exactly to OPENAI Exceptions
    def __init__(
        self,
        message: str,
        type: str,
        param: Optional[str],
        code: Optional[int],
    ):
        self.message = message
        self.type = type
        self.param = param
        self.code = code

    def to_dict(self) -> dict:
        return {
            "message": self.message,
            "type": self.type,
            "param": self.param,
            "code": self.code,
        }


limiter = Limiter(key_func=get_remote_address)
app = FastAPI()
app.state.limiter = limiter


@app.exception_handler(RateLimitExceeded)
async def _rate_limit_exceeded_handler(request: Request, exc: RateLimitExceeded):
    return JSONResponse(status_code=429, content={"detail": "Rate Limited!"})


app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
async def health_check():
    return {"status": "healthy"}

@app.post("/model/{model_id}/converse")
async def converse(model_id: str, request: Request):
    """
    Fake Bedrock 'converse' endpoint. 
    Returns a single JSON response according to the Bedrock response schema.
    """
    body = await request.json()

    # Simulate random processing delay (optional)
    # await asyncio.sleep(random.uniform(1.0, 3.0))

    # You could inspect 'body' here to see the user's messages or parameters.
    # For example: messages = body.get("messages", [])
    # Then craft a response. Here we just hard-code a sample.

    # A minimal valid Bedrock-like response
    response_data = {
        "output": {
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "text": "Hello there! This is a fake response from the Bedrock model."
                    }
                ]
            }
        },
        "stopReason": "end_turn",
        "usage": {
            "inputTokens": 30,
            "outputTokens": 10,
            "totalTokens": 40
        },
        "metrics": {
            "latencyMs": 1234
        }
    }

    # Return a JSON response
    return JSONResponse(content=response_data)


@app.post("/chat/completions")
@app.post("/v1/chat/completions")
async def completion(request: Request):
    """
    Completion endpoint that either returns:
      - A normal (non-streaming) completion with a random 1–3 second delay
      - A streaming response with multiple chunks and random 0.2–0.8 second delays
    """
    body = await request.json()
    stream_requested = body.get("stream", False)

    if stream_requested:
        # Simulate a small initial delay before the streaming starts
        #await asyncio.sleep(random.uniform(0.8, 1.5))

        # Return a streaming response
        async def stream_generator():
            # These are pseudo "token" parts of a response.
            content_parts = [
                "Hello",
                " there,",
                " how ",
                "can ",
                "I ",
                "assist ",
                "you ",
                "today?",
            ]

            # Stream each part in a chunk
            for i, part in enumerate(content_parts):
                # Build a chunk that mimics OpenAI's streaming format
                chunk_data = {
                    "id": "chatcmpl-123",
                    "object": "chat.completion.chunk",
                    "created": 1677652288,
                    "model": "gpt-3.5-turbo-0301",
                    "choices": [
                        {
                            "delta": {
                                # The first chunk includes "role"
                                **({"role": "assistant"} if i == 0 else {}),
                                "content": part,
                            },
                            "index": 0,
                            "finish_reason": None,
                        }
                    ],
                }
                yield f"data: {json.dumps(chunk_data)}\n\n"
                #await asyncio.sleep(random.uniform(0.2, 0.8))

            # Final chunk signaling the end
            final_chunk = {
                "id": "chatcmpl-123",
                "object": "chat.completion.chunk",
                "created": 1677652288,
                "model": "gpt-3.5-turbo-0301",
                "choices": [
                    {
                        "delta": {},
                        "index": 0,
                        "finish_reason": "stop",
                    }
                ],
            }
            yield f"data: {json.dumps(final_chunk)}\n\n"
            # The [DONE] message
            yield "data: [DONE]\n\n"

        return StreamingResponse(stream_generator(), media_type="text/event-stream")

    else:
        # Normal non-streaming response with random 1–3 second delay
        #await asyncio.sleep(random.uniform(1.0, 3.0))
        return {
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-3.5-turbo-0301",
            "system_fingerprint": "fp_44709d6fcb",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Hello there, how may I assist you today?",
                    },
                    "logprobs": None,
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 9, "completion_tokens": 12, "total_tokens": 21},
        }


if __name__ == "__main__":
    port = 8080
    while True:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        result = sock.connect_ex(("0.0.0.0", port))
        if result != 0:
            print(f"Port {port} is available, starting server on {port}...")
            break
        else:
            port += 1

    uvicorn.run(app, host="0.0.0.0", port=port)
