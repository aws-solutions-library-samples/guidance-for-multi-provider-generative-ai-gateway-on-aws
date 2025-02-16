# fake_openai_server.py

from fastapi import FastAPI, Request, status, HTTPException, Depends
from fastapi.responses import StreamingResponse
from fastapi.security import OAuth2PasswordBearer
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi import FastAPI, Request, HTTPException, UploadFile, File
import httpx, os, json
from openai import AsyncOpenAI
from typing import Optional
from slowapi import Limiter
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from fastapi.responses import PlainTextResponse


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


@app.post("/chat/completions")
@app.post("/v1/chat/completions")
@limiter.limit("100/minute")
async def completion(request: Request):
    return {
        "id": "chatcmpl-123",
        "object": "chat.completion",
        "created": 1677652288,
        "model": None,
        "system_fingerprint": "fp_44709d6fcb",
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "\n\nHello there, how may I assist you today?",
                },
                "logprobs": None,
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 9, "completion_tokens": 12, "total_tokens": 21},
    }


if __name__ == "__main__":
    import socket
    import uvicorn

    port = 8080
    while True:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        result = sock.connect_ex(("0.0.0.0", port))
        if result != 0:
            print(f"Port {port} is available, starting server...")
            break
        else:
            port += 1

    uvicorn.run(app, host="0.0.0.0", port=port)
