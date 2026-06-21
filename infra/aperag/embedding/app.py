import os
import time
from typing import Any

from fastapi import FastAPI, HTTPException
from fastembed import TextEmbedding
from pydantic import BaseModel, Field


MODEL_NAME = os.getenv(
    "EMBEDDING_MODEL",
    "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
)
CACHE_DIR = os.getenv("EMBEDDING_CACHE_DIR", "/models")

app = FastAPI(title="LIQUIDATION Embedding Service")
embedding_model: TextEmbedding | None = None


class EmbeddingRequest(BaseModel):
    model: str | None = None
    input: str | list[str] = Field(..., min_length=1)
    encoding_format: str | None = None


def get_model() -> TextEmbedding:
    global embedding_model
    if embedding_model is None:
        embedding_model = TextEmbedding(model_name=MODEL_NAME, cache_dir=CACHE_DIR)
    return embedding_model


def normalize_input(value: str | list[str]) -> list[str]:
    if isinstance(value, str):
        texts = [value]
    else:
        texts = value

    cleaned = [text for text in texts if isinstance(text, str) and text.strip()]
    if not cleaned:
        raise HTTPException(status_code=400, detail="input must contain at least one non-empty string")
    return cleaned


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "model": MODEL_NAME,
        "cache_dir": CACHE_DIR,
        "loaded": embedding_model is not None,
    }


@app.get("/v1/models")
def models() -> dict[str, Any]:
    return {
        "object": "list",
        "data": [
            {
                "id": MODEL_NAME,
                "object": "model",
                "created": 0,
                "owned_by": "liquidation-local",
            }
        ],
    }


@app.post("/v1/embeddings")
def embeddings(request: EmbeddingRequest) -> dict[str, Any]:
    requested_model = request.model or MODEL_NAME
    if requested_model != MODEL_NAME:
        raise HTTPException(status_code=400, detail=f"unsupported embedding model: {requested_model}")

    texts = normalize_input(request.input)
    model = get_model()
    vectors = list(model.embed(texts))

    data = []
    for index, vector in enumerate(vectors):
        data.append(
            {
                "object": "embedding",
                "index": index,
                "embedding": vector.tolist(),
            }
        )

    prompt_tokens = sum(max(1, len(text.split())) for text in texts)
    return {
        "object": "list",
        "data": data,
        "model": MODEL_NAME,
        "usage": {
            "prompt_tokens": prompt_tokens,
            "total_tokens": prompt_tokens,
        },
        "created": int(time.time()),
    }
