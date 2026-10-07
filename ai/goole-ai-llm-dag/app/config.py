import os
from dotenv import load_dotenv

load_dotenv()

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")

GOOGLE_CLOUD_PROJECT = os.getenv(
    "GOOGLE_CLOUD_PROJECT",
    "gen-lang-client-0915029637"
)

GOOGLE_GENAI_USE_VERTEXAI = os.getenv(
    "GOOGLE_GENAI_USE_VERTEXAI",
    "False"
)

ACTIVE_MODELS = [
    "gemma-4-26b-a4b-it",
]

MAX_OUTPUT_TOKENS = 1000
TEMPERATURE = 0.2
