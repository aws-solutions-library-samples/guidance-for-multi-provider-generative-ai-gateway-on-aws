resource "aws_secretsmanager_secret" "litellm_other_secrets" {
  name_prefix = "LiteLLMApiKeySecret-"
}

resource "aws_secretsmanager_secret_version" "litellm_other_secrets_ver" {
  secret_id = aws_secretsmanager_secret.litellm_other_secrets.id

  secret_string = jsonencode({
    OPENAI_API_KEY         = var.openai_api_key
    AZURE_OPENAI_API_KEY   = var.azure_openai_api_key
    AZURE_API_KEY          = var.azure_api_key
    ANTHROPIC_API_KEY      = var.anthropic_api_key
    GROQ_API_KEY           = var.groq_api_key
    COHERE_API_KEY         = var.cohere_api_key
    CO_API_KEY             = var.co_api_key
    HF_TOKEN               = var.hf_token
    HUGGINGFACE_API_KEY    = var.huggingface_api_key
    DATABRICKS_API_KEY     = var.databricks_api_key
    GEMINI_API_KEY         = var.gemini_api_key
    CODESTRAL_API_KEY      = var.codestral_api_key
    MISTRAL_API_KEY        = var.mistral_api_key
    AZURE_AI_API_KEY       = var.azure_ai_api_key
    NVIDIA_NIM_API_KEY     = var.nvidia_nim_api_key
    XAI_API_KEY            = var.xai_api_key
    PERPLEXITYAI_API_KEY   = var.perplexityai_api_key
    GITHUB_API_KEY         = var.github_api_key
    DEEPSEEK_API_KEY       = var.deepseek_api_key
    AI21_API_KEY           = var.ai21_api_key
    LANGSMITH_API_KEY      = var.langsmith_api_key
  })
}