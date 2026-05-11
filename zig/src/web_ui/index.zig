pub const ChatPanel = @import("ChatPanel.zig");
pub const components = struct {
    pub const AgentInterface = @import("components/AgentInterface.zig");
    pub const AttachmentTile = @import("components/AttachmentTile.zig");
    pub const ConsoleBlock = @import("components/ConsoleBlock.zig");
    pub const CustomProviderCard = @import("components/CustomProviderCard.zig");
    pub const ExpandableSection = @import("components/ExpandableSection.zig");
    pub const Input = @import("components/Input.zig");
    pub const message_renderer_registry = @import("components/message_renderer_registry.zig");
    pub const MessageEditor = @import("components/MessageEditor.zig");
    pub const MessageList = @import("components/MessageList.zig");
    pub const Messages = @import("components/Messages.zig");
    pub const ProviderKeyInput = @import("components/ProviderKeyInput.zig");
    pub const SandboxedIframe = @import("components/SandboxedIframe.zig");
    pub const StreamingMessageContainer = @import("components/StreamingMessageContainer.zig");
    pub const ThinkingBlock = @import("components/ThinkingBlock.zig");
    pub const sandbox = struct {
        pub const ArtifactsRuntimeProvider = @import("components/sandbox/ArtifactsRuntimeProvider.zig");
        pub const AttachmentsRuntimeProvider = @import("components/sandbox/AttachmentsRuntimeProvider.zig");
        pub const ConsoleRuntimeProvider = @import("components/sandbox/ConsoleRuntimeProvider.zig");
        pub const FileDownloadRuntimeProvider = @import("components/sandbox/FileDownloadRuntimeProvider.zig");
        pub const RuntimeMessageBridge = @import("components/sandbox/RuntimeMessageBridge.zig");
        pub const RuntimeMessageRouter = @import("components/sandbox/RuntimeMessageRouter.zig");
        pub const SandboxRuntimeProvider = @import("components/sandbox/SandboxRuntimeProvider.zig");
    };
};
pub const dialogs = struct {
    pub const ApiKeyPromptDialog = @import("dialogs/ApiKeyPromptDialog.zig");
    pub const AttachmentOverlay = @import("dialogs/AttachmentOverlay.zig");
    pub const CustomProviderDialog = @import("dialogs/CustomProviderDialog.zig");
    pub const ModelSelector = @import("dialogs/ModelSelector.zig");
    pub const PersistentStorageDialog = @import("dialogs/PersistentStorageDialog.zig");
    pub const ProvidersModelsTab = @import("dialogs/ProvidersModelsTab.zig");
    pub const SessionListDialog = @import("dialogs/SessionListDialog.zig");
    pub const SettingsDialog = @import("dialogs/SettingsDialog.zig");
};
pub const prompts = @import("prompts/prompts.zig");
pub const storage = struct {
    pub const app_storage = @import("storage/app_storage.zig");
    pub const store = @import("storage/store.zig");
    pub const types = @import("storage/types.zig");
    pub const backends = struct {
        pub const indexeddb_storage_backend = @import("storage/backends/indexeddb_storage_backend.zig");
    };
    pub const stores = struct {
        pub const custom_providers_store = @import("storage/stores/custom_providers_store.zig");
        pub const provider_keys_store = @import("storage/stores/provider_keys_store.zig");
        pub const sessions_store = @import("storage/stores/sessions_store.zig");
        pub const settings_store = @import("storage/stores/settings_store.zig");
    };
};
pub const tools = struct {
    pub const artifacts = @import("tools/artifacts/index.zig");
    pub const extract_document = @import("tools/extract_document.zig");
    pub const index = @import("tools/index.zig");
    pub const javascript_repl = @import("tools/javascript_repl.zig");
    pub const renderer_registry = @import("tools/renderer_registry.zig");
    pub const types = @import("tools/types.zig");
    pub const renderers = struct {
        pub const BashRenderer = @import("tools/renderers/BashRenderer.zig");
        pub const CalculateRenderer = @import("tools/renderers/CalculateRenderer.zig");
        pub const DefaultRenderer = @import("tools/renderers/DefaultRenderer.zig");
        pub const GetCurrentTimeRenderer = @import("tools/renderers/GetCurrentTimeRenderer.zig");
    };
};
pub const utils = struct {
    pub const attachment_utils = @import("utils/attachment_utils.zig");
    pub const auth_token = @import("utils/auth_token.zig");
    pub const format = @import("utils/format.zig");
    pub const i18n = @import("utils/i18n.zig");
    pub const model_discovery = @import("utils/model_discovery.zig");
    pub const proxy_utils = @import("utils/proxy_utils.zig");
    pub const test_sessions = @import("utils/test_sessions.zig");
};

test {
    _ = ChatPanel;
    _ = components.AgentInterface;
    _ = components.sandbox.RuntimeMessageRouter;
    _ = dialogs.ModelSelector;
    _ = prompts;
    _ = storage.stores.sessions_store;
    _ = tools.artifacts;
    _ = utils.i18n;
}
