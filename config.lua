-- LLM settings for ai/run.lua (llama.cpp server, OpenAI compatible API).
return {
  llm = {
    -- Full address of the chat completions endpoint
    url = "http://localhost:8000/v1/chat/completions",

    -- Model name, only needed by servers that serve several models (optional)
    -- model = "my-model",

    timeout = 10,
    max_tokens = 234,    -- the answer must fit in the dialog box: 9 lines * 26 chars
    temperature = 0.7,

    -- true: do not call the LLM
    fake = false,
  },
}