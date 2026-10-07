# Gemini LLM DAG

A modular **LLM DAG (Directed Acyclic Graph)** application built with **Python, FastAPI, Jinja2, and Google's Gemini API**.

The project demonstrates how a single user request can be processed through multiple specialized LLM nodes before producing the final answer.

Instead of asking one model to perform every task in a single prompt, the application separates the workflow into:

```text
User Request
     │
     ▼
┌───────────┐
│  Planner  │
└─────┬─────┘
      │
      ▼
┌───────────┐
│ Research  │
└─────┬─────┘
      │
      ▼
┌───────────┐
│ Analysis  │
└─────┬─────┘
      │
      ▼
┌───────────┐
│  Review   │
└─────┬─────┘
      │
      ▼
┌───────────┐
│   Final   │
└─────┬─────┘
      │
      ▼
 Final Answer
```

Each node has a specific responsibility and can be monitored independently for model usage, execution time, and generated output.

---

## Use Case

The main use case is **multi-stage LLM reasoning for complex user requests**.

A conventional LLM application might send a request directly to a model:

```text
User Request
     │
     ▼
   LLM
     │
     ▼
 Answer
```

This project instead decomposes the task into multiple stages:

```text
                    ┌─────────────┐
                    │ User Prompt │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │   Planner   │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  Research   │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │   Analysis  │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │   Review    │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │    Final    │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │ Final Answer│
                    └─────────────┘
```

This architecture is useful when answer quality benefits from separating:

* planning
* information gathering
* reasoning
* quality review
* final response generation

The final node receives the outputs of the previous stages and is instructed to return only the answer intended for the user.

---

## Architecture

The application has four main layers.

### 1. FastAPI API

FastAPI provides the HTTP interface:

```text
POST /dag
```

The endpoint accepts a user prompt and executes the DAG.

A health endpoint is also provided:

```text
GET /health
```

The application also serves the web interface from:

```text
GET /
```

The API is implemented in `app/main.py`.

---

### 2. DAG Orchestrator

`app/dag.py` is responsible for executing the workflow.

The DAG currently contains five nodes:

1. Planner
2. Research
3. Analysis
4. Review
5. Final

The nodes are executed sequentially, with later nodes receiving relevant output from earlier nodes.

The resulting structure contains both the final answer and the individual node results.

---

### 3. Gemini Model Wrapper

`app/gemini.py` provides a single interface:

```python
call_gemini(...)
```

The DAG does not need to know the details of the Google GenAI SDK.

The wrapper handles:

* Gemini API requests
* model selection
* model fallback
* retries
* temporary server errors
* quota errors
* empty model responses
* generated text extraction
* token usage extraction
* execution timing

The wrapper also distinguishes generated candidate tokens from thinking tokens when usage metadata is available.

---

### 4. Jinja2 Prompt Templates

Each DAG node has its own prompt template:

```text
prompts/
├── planner.j2
├── research.j2
├── analysis.j2
├── review.j2
└── final.j2
```

Jinja2 is used to inject the current request and outputs from upstream nodes into each prompt.

This keeps orchestration logic separate from prompt engineering.

---

# DAG Nodes

## Planner

The Planner receives the original user request.

Its job is to create a concise execution plan.

It identifies:

* the main question
* important concepts
* required factual or technical information
* ambiguities
* guidance for the research stage

The Planner does **not** answer the user directly.

---

## Research

The Research node receives:

```text
User Request
Planner Output
```

It produces the factual and technical information required by downstream stages.

The prompt explicitly asks the model to distinguish between:

* established facts
* technical details
* assumptions
* caveats

It also instructs the model not to claim that it performed external web research.

---

## Analysis

The Analysis node receives:

```text
User Request
Planner Output
Research Output
```

It determines:

* what information is directly relevant
* what should be included
* what should be omitted
* whether there are contradictions
* whether assumptions are unsupported
* how the final answer can be explained clearly

The Analysis node does not produce the final user-facing answer.

---

## Review

The Review node acts as a quality-control stage.

It receives:

```text
User Request
Research Output
Analysis Output
```

It checks for:

* factual problems
* contradictions
* missing information
* unnecessary complexity
* unsupported claims
* unclear explanations

It then provides corrections and recommendations for the final node.

---

## Final

The Final node receives the complete upstream context:

```text
User Request
Planner
Research
Analysis
Review
```

Its purpose is to convert the intermediate processing into the final response.

The prompt explicitly instructs the model to:

* answer the user's request directly
* return only the final answer
* avoid exposing the internal DAG
* avoid mentioning the planning/research/review process
* avoid exposing internal reasoning
* use normal Markdown when appropriate

This makes the intermediate DAG an internal processing mechanism rather than something exposed to the end user.

---

# Project Structure

```text
.
├── app/
│   ├── __init__.py
│   ├── config.py
│   ├── dag.py
│   ├── gemini.py
│   ├── main.py
│   ├── models.py
│   └── schemas.py
│
├── prompts/
│   ├── analysis.j2
│   ├── dag.yaml.j2
│   ├── final.j2
│   ├── planner.j2
│   ├── research.j2
│   └── review.j2
│
└── templates/
    └── index.html
```

The project separates:

```text
Application code
       │
       ├── API
       ├── DAG orchestration
       ├── Gemini integration
       └── Data models
       
Prompt layer
       │
       ├── Planner
       ├── Research
       ├── Analysis
       ├── Review
       └── Final
       
Presentation layer
       │
       └── Web UI
```

---

# Requirements

The project requires Python and the following main packages:

```text
fastapi
uvicorn
jinja2
pydantic
python-dotenv
google-genai
```

Install the dependencies using your project's preferred Python environment/package manager.

---

# Google AI Studio / Gemini API

The application uses Google's GenAI Python SDK.

Set your Gemini API key as an environment variable:

```bash
export GEMINI_API_KEY="YOUR_API_KEY"
```

On Windows PowerShell:

```powershell
$env:GEMINI_API_KEY="YOUR_API_KEY"
```

The Gemini wrapper accepts either:

```text
GEMINI_API_KEY
```

or:

```text
GOOGLE_API_KEY
```

and raises an error if neither is configured.

---

# Configuration

Configuration is loaded from environment variables.

The project defines:

```python
GEMINI_API_KEY
GOOGLE_CLOUD_PROJECT
GOOGLE_GENAI_USE_VERTEXAI
```

The default configuration includes:

```python
MAX_OUTPUT_TOKENS = 1000
TEMPERATURE = 0.2
```

The currently configured active model is:

```text
gemma-4-26b-a4b-it
```

The Gemini wrapper also maintains a fallback model list so that the application can attempt another configured model when a model encounters quota, temporary, empty-response, or other failures.

---

# Running the Application

Start the FastAPI application with:

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

Then open:

```text
http://localhost:8000
```

---

# Health Check

Verify that the API is running:

```bash
curl http://localhost:8000/health
```

Expected response:

```json
{
  "status": "ok"
}
```

---

# API

## POST `/dag`

Send a prompt to the DAG.

Example:

```bash
curl -X POST http://localhost:8000/dag \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Explain how Docker containers work."
  }'
```

The request model contains a single required field:

```json
{
  "prompt": "..."
}
```

---

# Response

The API returns:

```json
{
  "answer": "...",
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "total_tokens": 0,
    "reported_total_tokens": 0,
    "nodes": {}
  },
  "nodes": {}
}
```

The response contains:

### `answer`

The final user-facing answer generated by the Final node.

### `usage`

Aggregated token usage across all DAG nodes.

### `nodes`

Individual results from:

```text
planner
research
analysis
review
final
```

Each node records information such as:

```json
{
  "model": "...",
  "input_tokens": 0,
  "output_tokens": 0,
  "total_tokens": 0,
  "elapsed_seconds": 0.0,
  "text": "..."
}
```

---

# Token Usage

The application records token usage for each Gemini call.

For each node it tracks:

```text
input_tokens
output_tokens
thoughts_tokens
total_tokens
```

The DAG then aggregates the node-level usage.

Two totals are retained:

```text
total_tokens
reported_total_tokens
```

`reported_total_tokens` represents the sum of Google's reported `total_token_count` values.

The DAG's `total_tokens` is calculated from:

```text
input_tokens + output_tokens
```

This distinction is useful because Google's reported total can differ from the simple input-plus-output calculation.

---

# Model Reliability

The Gemini wrapper includes several reliability mechanisms.

## Retry

Transient failures and empty responses can be retried.

The default retry configuration is:

```text
retries = 2
retry_delay = 2 seconds
temporary_retry_delay = 3 seconds
```

Therefore, a model can be attempted up to three times before the wrapper moves to the next model.

## Quota Handling

Quota/rate-limit errors are classified separately.

Examples include:

```text
429
RESOURCE_EXHAUSTED
quota
rate limit
```

When a quota error occurs, the wrapper moves to the next model rather than repeatedly retrying the same exhausted model.

## Temporary Errors

Temporary server-side errors such as:

```text
500
503
Internal Server Error
Service Unavailable
```

are treated as retryable failures.

## Empty Responses

Gemini can return a successful API response without usable generated text.

The wrapper therefore explicitly checks the response text and also falls back to inspecting candidates and content parts.

---

# Why Use an LLM DAG?

The architecture provides several practical advantages over a single large prompt.

## Separation of Responsibilities

Each node has a clearly defined task.

```text
Planner  → What needs to be done?
Research → What information is relevant?
Analysis → How should the information be interpreted?
Review   → Is the reasoning sound?
Final    → What should the user see?
```

This makes the prompts easier to develop and maintain.

## Observability

Each node reports:

* selected model
* input tokens
* output tokens
* total tokens
* execution time
* generated text

This makes it possible to identify expensive or slow stages.

## Prompt Modularity

Prompts are maintained independently from Python orchestration code.

For example:

```text
prompts/planner.j2
prompts/research.j2
prompts/analysis.j2
prompts/review.j2
prompts/final.j2
```

A prompt can therefore be refined without changing the DAG execution code.

## Quality Control

The dedicated Review stage provides a second opportunity to identify:

* unsupported claims
* contradictions
* missing information
* unclear explanations
* unnecessary complexity

before the final answer is generated.

---

# Execution Flow

For a request such as:

```text
Explain the advantages and disadvantages of running
PostgreSQL inside Docker.
```

the application processes it approximately as follows:

### Step 1 — Planner

```text
Input:
User request

Output:
A concise plan identifying the concepts
that need to be covered.
```

### Step 2 — Research

```text
Input:
User request
Planner output

Output:
Relevant technical information,
facts, assumptions and caveats.
```

### Step 3 — Analysis

```text
Input:
User request
Planner output
Research output

Output:
Relevant information,
omissions,
contradictions,
and recommended answer structure.
```

### Step 4 — Review

```text
Input:
User request
Research output
Analysis output

Output:
Corrections and recommendations.
```

### Step 5 — Final

```text
Input:
User request
Planner
Research
Analysis
Review

Output:
Final user-facing answer.
```

---

# Design Principle

The central design principle is:

> **Use specialized LLM stages rather than asking one model call to perform the entire workflow.**

The DAG does not expose its internal processing to the user.

The user sees:

```text
Request
   ↓
Final Answer
```

while internally the system performs:

```text
Request
   ↓
Planner
   ↓
Research
   ↓
Analysis
   ↓
Review
   ↓
Final
   ↓
Answer
```

This separation allows the system to evolve into more sophisticated DAGs without changing the basic user-facing API.

---

# Extending the DAG

New nodes can be added by creating a prompt template and adding a corresponding `run_node()` call in `app/dag.py`.

For example:

```text
prompts/
├── planner.j2
├── research.j2
├── analysis.j2
├── review.j2
├── fact_check.j2
└── final.j2
```

A future workflow could become:

```text
Planner
   │
   ▼
Research
   │
   ▼
Analysis
   │
   ├──────────────► Fact Check
   │
   ▼
Review
   │
   ▼
Final
```

The existing architecture is therefore suitable as a foundation for more advanced multi-stage LLM workflows.

---

# Prompt Templates

Prompt templates use Jinja2 variables.

For example:

```jinja2
User request:

{{ prompt }}

Planner:

{{ planner }}

Research:

{{ research }}
```

The DAG renders these templates before sending them to Gemini.

This allows the same node implementation to receive different upstream context.

---

# Error Handling

If the DAG fails while processing a request, the FastAPI endpoint returns HTTP `503` with the underlying error message.

The API therefore distinguishes successful DAG execution from unavailable/failed model processing.

---

# Current Scope

This project currently implements a sequential text-generation DAG.

It is designed for:

* multi-stage reasoning
* prompt experimentation
* model experimentation
* token usage monitoring
* latency monitoring
* LLM reliability testing
* separating planning from final generation
* evaluating intermediate LLM outputs

The current Research node uses the model's existing knowledge and explicitly does **not** perform external web browsing.

---

# Future Extensions

Potential extensions include:

* parallel DAG branches
* external search/retrieval
* RAG
* document ingestion
* structured JSON outputs
* node-level model selection
* node-level temperature configuration
* persistent execution history
* cost tracking
* tracing and observability
* configurable DAG definitions
* human approval/review nodes
* asynchronous execution
* caching
* evaluation datasets
* automated quality scoring

The existing project already contains a Jinja2 template for representing DAG configuration, including node dependencies, models, token limits, temperature, and retry settings.

---

# Summary

This project is a practical example of a **multi-node LLM application using Google's Gemini API**.

Its main idea is simple:

```text
                    ┌──────────┐
                    │  Prompt  │
                    └────┬─────┘
                         │
                         ▼
                    ┌──────────┐
                    │ Planner  │
                    └────┬─────┘
                         │
                         ▼
                    ┌──────────┐
                    │ Research │
                    └────┬─────┘
                         │
                         ▼
                    ┌──────────┐
                    │ Analysis │
                    └────┬─────┘
                         │
                         ▼
                    ┌──────────┐
                    │  Review  │
                    └────┬─────┘
                         │
                         ▼
                    ┌──────────┐
                    │  Final   │
                    └────┬─────┘
                         │
                         ▼
                    ┌──────────┐
                    │  Answer  │
                    └──────────┘
```

Each stage has a focused responsibility, while the Gemini wrapper provides model execution, retries, fallback handling, token accounting, and timing information.

The result is a small but extensible foundation for building and experimenting with **production-style multi-stage LLM workflows**.

