const std = @import("std");

pub const types = @import("types.zig");
pub const event_stream = @import("event_stream.zig");
pub const api_registry = @import("api_registry.zig");
pub const models = @import("models.zig");
pub const validation = @import("validation.zig");
const models_generated = @import("models.generated.zig");
pub const simple_options = @import("simple_options.zig");
pub const transform_messages = @import("transform_messages.zig");
pub const env_api_keys = @import("env_api_keys.zig");
pub const overflow = @import("overflow.zig");

// Re-export commonly used types at root
pub const Message = types.Message;
pub const UserMessage = types.UserMessage;
pub const AssistantMessage = types.AssistantMessage;
pub const ToolResultMessage = types.ToolResultMessage;
pub const ContentBlock = types.ContentBlock;
pub const Tool = types.Tool;
pub const ToolCall = types.ToolCall;
pub const Context = types.Context;
pub const Model = types.Model;
pub const Usage = types.Usage;
pub const StopReason = types.StopReason;
pub const SimpleStreamOptions = types.SimpleStreamOptions;
pub const AssistantMessageEvent = event_stream.AssistantMessageEvent;
pub const AssistantMessageEventStream = event_stream.AssistantMessageEventStream;
pub const createAssistantMessageEventStream = event_stream.createAssistantMessageEventStream;
pub const stream = api_registry.stream;
pub const streamSimple = api_registry.streamSimple;
pub const complete = api_registry.complete;
pub const completeSimple = api_registry.completeSimple;
pub const registerApiProvider = api_registry.registerApiProvider;
pub const getApiProvider = api_registry.getApiProvider;
pub const getApiProviders = api_registry.getApiProviders;
pub const clearApiProviders = api_registry.clearApiProviders;
pub const registerModel = models.registerModel;
pub const getModel = models.getModel;
pub const getProviders = models.getProviders;
pub const getModels = models.getModels;
pub const calculateCost = models.calculateCost;
pub const supportsXhigh = models.supportsXhigh;
pub const modelsAreEqual = models.modelsAreEqual;
pub const validateToolArguments = validation.validateToolArguments;
pub const getEnvApiKey = env_api_keys.getEnvApiKey;
pub const isContextOverflow = overflow.isContextOverflow;

// Providers
pub const faux_provider = @import("providers/faux.zig");
pub const openai_completions_provider = @import("providers/openai_completions.zig");
pub const anthropic_messages_provider = @import("providers/anthropic_messages.zig");
pub const openai_responses_provider = @import("providers/openai_responses.zig");
pub const azure_openai_responses_provider = @import("providers/azure_openai_responses.zig");
pub const google_generative_ai_provider = @import("providers/google_generative_ai.zig");
pub const google_gemini_cli_provider = @import("providers/google_gemini_cli.zig");
pub const openai_codex_responses_provider = @import("providers/openai_codex_responses.zig");
pub const amazon_bedrock_provider = @import("providers/amazon_bedrock.zig");
pub const mistral_provider = @import("providers/mistral.zig");
pub const google_shared = @import("providers/google_shared.zig");

/// Initialize the ai module: register all built-in models and API providers.
/// Must be called once before using `getModel()` or `stream()`.
pub fn init() void {
    models_generated.registerAllModels();
    faux_provider.registerFauxProvider();
    openai_completions_provider.registerOpenAICompletionsProvider();
    anthropic_messages_provider.registerAnthropicMessagesProvider();
    openai_responses_provider.registerOpenAIResponsesProvider();
    azure_openai_responses_provider.registerAzureOpenAIResponsesProvider();
    google_generative_ai_provider.registerGoogleGenerativeAIProvider();
    google_gemini_cli_provider.registerGoogleGeminiCliProvider();
    openai_codex_responses_provider.registerOpenAICodexResponsesProvider();
    amazon_bedrock_provider.registerAmazonBedrockProvider();
    mistral_provider.registerMistralProvider();
}

test "ai root compiles" {
    _ = types.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } };
}
