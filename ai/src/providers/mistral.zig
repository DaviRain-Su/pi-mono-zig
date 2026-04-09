const ai = @import("../root.zig");
const openai_completions = @import("openai_completions.zig");

/// Stream responses from Mistral using the OpenAI-compatible chat completions API.
/// This is a thin wrapper around openai_completions with Mistral-specific base URL
/// resolution (https://api.mistral.ai/v1) registered under the mistral_conversations API.
pub fn streamMistral(model: ai.Model, context: ai.Context, options: ?ai.types.StreamOptions) ai.AssistantMessageEventStream {
    return openai_completions.streamOpenAICompletions(model, context, options);
}

/// Stream simplified responses from Mistral.
pub fn streamSimpleMistral(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    return openai_completions.streamSimpleOpenAICompletions(model, context, options);
}

pub fn registerMistralProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .mistral_conversations },
        .stream = streamMistral,
        .stream_simple = streamSimpleMistral,
    });
}

test "mistral provider compiles and registers" {
    registerMistralProvider();
}
