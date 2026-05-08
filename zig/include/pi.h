/*
 * pi.h - Pi Agent C ABI (v0.1 draft)
 * ----------------------------------
 *
 * This header is the cross-language SDK contract for the pi-mono-zig
 * coding-agent core. Bindings for Go / Rust / Python / Swift are expected
 * to be built on top of this surface.
 *
 * STATUS: v0.1 DRAFT. Names, signatures, and error codes are NOT YET FROZEN.
 * Once we hit v1.0 (after a real consumer like a Go binding is built), this
 * surface becomes append-only.
 *
 * DESIGN PRINCIPLES
 *   - Opaque handles. All stateful objects are pointers to forward-declared
 *     structs whose internal layout is intentionally hidden.
 *   - Errors are values. Every operation that can fail returns pi_status_t.
 *     No exceptions, no longjmp.
 *   - Strings are explicit (ptr + len) pairs. NUL-termination is never
 *     required; binary content (e.g. base64 image data) is binary-safe.
 *   - Callbacks pair with void* user_data, no captured environment.
 *   - All resources use matching new/free pairs. No GC, no implicit ownership.
 *
 * THREAD SAFETY
 *   - pi_session_t is shareable across threads if the caller guards it.
 *   - pi_stream_t and pi_agent_t are NOT thread-safe; one consumer per
 *     handle at a time. Use the abort signal to cancel from another thread.
 *   - Event callbacks are invoked single-threaded by the agent loop, even
 *     when underlying tool execution runs on multiple threads. Subscribers
 *     do NOT need their own synchronization for event delivery.
 *
 * MEMORY OWNERSHIP CONVENTIONS
 *   - Functions returning a const char* via out-parameters give the caller
 *     a borrowed pointer. The pointer is valid until the next call on the
 *     same handle, or until the handle is freed - whichever is first.
 *   - Functions returning a new pi_*_t* always require a matching pi_*_free.
 *   - Strings passed in (ptr + len) are copied internally; the caller may
 *     free their buffer immediately after the call returns.
 */

#ifndef PI_H
#define PI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================ */
/*  Versioning                                                  */
/* ============================================================ */

#define PI_VERSION_MAJOR 0
#define PI_VERSION_MINOR 1
#define PI_VERSION_PATCH 0
#define PI_VERSION_STRING "0.1.0"

const char* pi_version_string(void);
uint32_t    pi_abi_version(void);

/* ============================================================ */
/*  Error codes                                                 */
/* ============================================================ */

typedef enum {
    PI_OK                       = 0,
    PI_ERR_OOM                  = 1,
    PI_ERR_INVALID_ARG          = 2,
    PI_ERR_INVALID_STATE        = 3,
    PI_ERR_PROVIDER_NOT_FOUND   = 10,
    PI_ERR_API_KEY_MISSING      = 11,
    PI_ERR_HTTP                 = 12,
    PI_ERR_PARSE                = 13,
    PI_ERR_ABORTED              = 14,
    PI_ERR_TIMEOUT              = 15,
    PI_ERR_PERMISSION_DENIED    = 20,
    PI_ERR_TOOL_NOT_FOUND       = 21,
    PI_ERR_TOOL_FAILED          = 22,
    PI_ERR_RESOURCE_LIMIT       = 23,
    PI_ERR_EXTENSION_LOAD       = 30,
    PI_ERR_EXTENSION_DIGEST     = 31,
    PI_ERR_INTERNAL             = 99
} pi_status_t;

const char* pi_status_string(pi_status_t status);

typedef struct pi_session_s pi_session_t;
const char* pi_session_last_error(pi_session_t* session);

/* ============================================================ */
/*  Stream-level event types (for low-level pi_stream_t)        */
/* ============================================================ */

typedef enum {
    PI_STREAM_EVENT_START           = 1,
    PI_STREAM_EVENT_TEXT_START      = 2,
    PI_STREAM_EVENT_TEXT_DELTA      = 3,
    PI_STREAM_EVENT_TEXT_END        = 4,
    PI_STREAM_EVENT_THINKING_START  = 5,
    PI_STREAM_EVENT_THINKING_DELTA  = 6,
    PI_STREAM_EVENT_THINKING_END    = 7,
    PI_STREAM_EVENT_TOOLCALL_START  = 8,
    PI_STREAM_EVENT_TOOLCALL_DELTA  = 9,
    PI_STREAM_EVENT_TOOLCALL_END    = 10,
    PI_STREAM_EVENT_DONE            = 100,
    PI_STREAM_EVENT_ERROR           = 200
} pi_stream_event_type_t;

typedef enum {
    PI_ROLE_USER        = 1,
    PI_ROLE_ASSISTANT   = 2,
    PI_ROLE_TOOL_RESULT = 3
} pi_role_t;

typedef enum {
    PI_STOP_REASON_STOP      = 1,
    PI_STOP_REASON_LENGTH    = 2,
    PI_STOP_REASON_TOOL_USE  = 3,
    PI_STOP_REASON_ERROR     = 4,
    PI_STOP_REASON_ABORTED   = 5
} pi_stop_reason_t;

/* The 12 capabilities (see internals/coding-agent dossier §6).
 * A pi_principal_t carries an OR-set of these (bitmask). */
typedef enum {
    PI_CAP_FILE_READ        = 1 << 0,
    PI_CAP_FILE_WRITE       = 1 << 1,
    PI_CAP_NETWORK_REQUEST  = 1 << 2,
    PI_CAP_SHELL_RUN        = 1 << 3,
    PI_CAP_ENV_READ         = 1 << 4,
    PI_CAP_MODEL_CALL       = 1 << 5,
    PI_CAP_SESSION_READ     = 1 << 6,
    PI_CAP_SESSION_WRITE    = 1 << 7,
    PI_CAP_UI_NOTIFY        = 1 << 8,
    PI_CAP_TOOL_USE         = 1 << 9,
    PI_CAP_AGENT_SPAWN      = 1 << 10,
    PI_CAP_AGENT_DELEGATE   = 1 << 11,
    PI_CAP_ALL              = 0x0FFF
} pi_capability_t;

typedef enum {
    PI_RUNTIME_NATIVE        = 1,  /* D-12: NOT exposed to third parties */
    PI_RUNTIME_WASM          = 2,
    PI_RUNTIME_PROCESS_JSONL = 3
} pi_runtime_kind_t;

typedef enum {
    PI_EXEC_PARALLEL   = 0,
    PI_EXEC_SEQUENTIAL = 1
} pi_execution_mode_t;

typedef enum {
    PI_THINKING_OFF     = 0,
    PI_THINKING_MINIMAL = 1,
    PI_THINKING_LOW     = 2,
    PI_THINKING_MEDIUM  = 3,
    PI_THINKING_HIGH    = 4,
    PI_THINKING_XHIGH   = 5
} pi_thinking_level_t;

/* ============================================================ */
/*  Opaque handle forward declarations                          */
/* ============================================================ */

typedef struct pi_workspace_s       pi_workspace_t;
typedef struct pi_principal_s       pi_principal_t;
typedef struct pi_options_s         pi_options_t;
typedef struct pi_stream_s          pi_stream_t;
typedef struct pi_stream_event_s    pi_stream_event_t;
typedef struct pi_message_s         pi_message_t;
typedef struct pi_tool_result_s     pi_tool_result_t;
typedef struct pi_agent_s           pi_agent_t;
typedef struct pi_agent_event_s     pi_agent_event_t;
typedef struct pi_extension_s       pi_extension_t;
typedef struct pi_hook_event_s      pi_hook_event_t;

/* ============================================================ */
/*  Session                                                     */
/* ============================================================ */

pi_status_t pi_session_new(pi_session_t** out);
void        pi_session_free(pi_session_t* session);

/* ============================================================ */
/*  Workspace                                                   */
/* ============================================================ */

pi_status_t pi_workspace_new(pi_session_t* session,
                              const char* cwd, size_t cwd_len,
                              pi_workspace_t** out);
void        pi_workspace_free(pi_workspace_t* ws);
const char* pi_workspace_cwd(const pi_workspace_t* ws, size_t* out_len);

/* ============================================================ */
/*  Principal: capability-bearing identity (D-3)                */
/* ============================================================ */

pi_status_t pi_principal_new_trusted_built_in(const char* extension_id,
                                                size_t extension_id_len,
                                                pi_principal_t** out);

pi_status_t pi_principal_new(pi_runtime_kind_t runtime_kind,
                              const char* extension_id, size_t extension_id_len,
                              uint32_t grants_bitmask,
                              pi_principal_t** out);

pi_status_t pi_principal_grant(pi_principal_t* p, pi_capability_t cap);
pi_status_t pi_principal_revoke(pi_principal_t* p, pi_capability_t cap);
int         pi_principal_has(const pi_principal_t* p, pi_capability_t cap);

pi_status_t pi_principal_set_resource_limits(pi_principal_t* p,
                                               uint64_t max_children,
                                               uint64_t max_depth,
                                               uint64_t max_turns,
                                               uint64_t timeout_ms,
                                               uint64_t max_output_bytes,
                                               uint64_t max_output_lines);

pi_status_t pi_principal_set_tool_scopes(pi_principal_t* p,
                                           const char** tool_names);

void        pi_principal_free(pi_principal_t* p);

/* ============================================================ */
/*  Tool invocation (D-4: 8 tools, single dispatcher)           */
/* ============================================================ */

pi_status_t pi_tool_invoke(pi_workspace_t* ws,
                            pi_principal_t* principal,
                            const char* tool_name, size_t tool_name_len,
                            const char* args_json, size_t args_json_len,
                            const volatile int* abort_flag,
                            pi_tool_result_t** out_result);

pi_status_t pi_tool_schema_json(pi_session_t* session,
                                 const char* tool_name, size_t tool_name_len,
                                 const char** out_schema_json,
                                 size_t* out_len);

pi_status_t pi_tool_list_builtin(pi_session_t* session,
                                  const char*** out_names,
                                  size_t* out_count);

/* ============================================================ */
/*  Tool result inspection                                      */
/* ============================================================ */

int    pi_tool_result_is_error(const pi_tool_result_t* r);
size_t pi_tool_result_content_count(const pi_tool_result_t* r);

typedef enum {
    PI_CONTENT_TEXT     = 1,
    PI_CONTENT_IMAGE    = 2,
    PI_CONTENT_THINKING = 3,
    PI_CONTENT_TOOL_USE = 4
} pi_content_type_t;

pi_status_t pi_tool_result_content_at(const pi_tool_result_t* r, size_t index,
                                        pi_content_type_t* out_type,
                                        const char** out_text, size_t* out_text_len,
                                        const char** out_mime, size_t* out_mime_len);

pi_status_t pi_tool_result_details_json(const pi_tool_result_t* r,
                                          const char** out_json, size_t* out_len);

void pi_tool_result_free(pi_tool_result_t* r);

/* ============================================================ */
/*  Stream options builder                                      */
/* ============================================================ */

pi_status_t pi_options_new(pi_options_t** out);
void        pi_options_free(pi_options_t* opts);

pi_status_t pi_options_set_api_key(pi_options_t* opts,
                                     const char* key, size_t len);
pi_status_t pi_options_set_temperature(pi_options_t* opts, double t);
pi_status_t pi_options_set_max_tokens(pi_options_t* opts, uint32_t n);
pi_status_t pi_options_set_timeout_ms(pi_options_t* opts, uint32_t ms);
pi_status_t pi_options_set_thinking(pi_options_t* opts, pi_thinking_level_t level);
pi_status_t pi_options_add_header(pi_options_t* opts,
                                    const char* k, size_t k_len,
                                    const char* v, size_t v_len);
pi_status_t pi_options_set_provider_json(pi_options_t* opts,
                                           const char* json, size_t len);
pi_status_t pi_options_set_abort_flag(pi_options_t* opts,
                                        const volatile int* abort_flag);

/* ============================================================ */
/*  Streaming LLM call (low-level)                              */
/* ============================================================ */

pi_status_t pi_stream_start(pi_session_t* session,
                              const char* api, size_t api_len,
                              const char* model, size_t model_len,
                              const char* system, size_t system_len,
                              const char* messages_json, size_t messages_json_len,
                              const char* tools_json, size_t tools_json_len,
                              const pi_options_t* opts,
                              pi_stream_t** out);

pi_status_t pi_stream_next(pi_stream_t* s, const pi_stream_event_t** out_event);

pi_stream_event_type_t pi_stream_event_type(const pi_stream_event_t* e);
const char*            pi_stream_event_delta(const pi_stream_event_t* e, size_t* out_len);
const char*            pi_stream_event_tool_name(const pi_stream_event_t* e, size_t* out_len);
const char*            pi_stream_event_tool_call_id(const pi_stream_event_t* e, size_t* out_len);
const char*            pi_stream_event_error_message(const pi_stream_event_t* e, size_t* out_len);
uint32_t               pi_stream_event_content_index(const pi_stream_event_t* e);

pi_status_t pi_stream_final_message_json(pi_stream_t* s,
                                           const char** out_json, size_t* out_len);

void pi_stream_free(pi_stream_t* s);

/* ============================================================ */
/*  Agent: high-level handle                                    */
/* ============================================================ */

typedef struct {
    const char*  system_prompt;
    size_t       system_prompt_len;
    const char*  api;
    size_t       api_len;
    const char*  model;
    size_t       model_len;
    const char*  api_key;
    size_t       api_key_len;
    pi_thinking_level_t thinking;
    pi_execution_mode_t tool_exec;
} pi_agent_config_t;

pi_status_t pi_agent_new(pi_session_t* session,
                          pi_workspace_t* ws,
                          pi_principal_t* principal,
                          const pi_agent_config_t* config,
                          pi_agent_t** out);
void        pi_agent_free(pi_agent_t* a);

/* ============================================================ */
/*  Agent prompting (D-2: split from anytype)                   */
/* ============================================================ */

pi_status_t pi_agent_prompt_text(pi_agent_t* a,
                                   const char* text, size_t len);

pi_status_t pi_agent_prompt_text_with_image(pi_agent_t* a,
                                              const char* text, size_t text_len,
                                              const char* image_base64,
                                              size_t image_base64_len,
                                              const char* mime, size_t mime_len);

pi_status_t pi_agent_prompt_message_json(pi_agent_t* a,
                                           const char* message_json,
                                           size_t len);

pi_status_t pi_agent_prompt_messages_json(pi_agent_t* a,
                                             const char* messages_json,
                                             size_t len);

pi_status_t pi_agent_steer_text(pi_agent_t* a,
                                  const char* text, size_t len);
pi_status_t pi_agent_follow_up_text(pi_agent_t* a,
                                      const char* text, size_t len);
pi_status_t pi_agent_continue_run(pi_agent_t* a);
void        pi_agent_abort(pi_agent_t* a);

/* ============================================================ */
/*  Agent: tool registration                                    */
/* ============================================================ */

pi_status_t pi_agent_attach_extension(pi_agent_t* a, pi_extension_t* ext);

pi_status_t pi_agent_set_builtin_tool_enabled(pi_agent_t* a,
                                                const char* tool_name, size_t len,
                                                int enabled);

/* ============================================================ */
/*  Agent: events (D-1: opaque + getters, agent-level)          */
/* ============================================================ */

typedef enum {
    PI_EVENT_AGENT_START            = 1,
    PI_EVENT_AGENT_END              = 2,
    PI_EVENT_TURN_START             = 3,
    PI_EVENT_TURN_END               = 4,
    PI_EVENT_MESSAGE_START          = 5,
    PI_EVENT_MESSAGE_UPDATE         = 6,
    PI_EVENT_MESSAGE_END            = 7,
    PI_EVENT_TOOL_EXECUTION_START   = 8,
    PI_EVENT_TOOL_EXECUTION_UPDATE  = 9,
    PI_EVENT_TOOL_EXECUTION_END     = 10
} pi_event_type_t;

typedef int (*pi_agent_event_fn)(void* user_data, const pi_agent_event_t* event);

pi_status_t pi_agent_subscribe(pi_agent_t* a,
                                 pi_agent_event_fn fn,
                                 void* user_data);
pi_status_t pi_agent_unsubscribe(pi_agent_t* a,
                                   pi_agent_event_fn fn,
                                   void* user_data);

pi_event_type_t pi_event_type(const pi_agent_event_t* e);
const char*     pi_event_tool_call_id(const pi_agent_event_t* e, size_t* out_len);
const char*     pi_event_tool_name(const pi_agent_event_t* e, size_t* out_len);
const char*     pi_event_args_json(const pi_agent_event_t* e, size_t* out_len);
const char*     pi_event_message_json(const pi_agent_event_t* e, size_t* out_len);
const char*     pi_event_error_message(const pi_agent_event_t* e, size_t* out_len);
int             pi_event_is_error(const pi_agent_event_t* e);

/* ============================================================ */
/*  Agent: state queries                                        */
/* ============================================================ */

int         pi_agent_is_streaming(const pi_agent_t* a);
size_t      pi_agent_message_count(const pi_agent_t* a);
size_t      pi_agent_steering_queue_len(const pi_agent_t* a);
size_t      pi_agent_follow_up_queue_len(const pi_agent_t* a);

pi_status_t pi_agent_message_at_json(const pi_agent_t* a, size_t index,
                                       const char** out_json, size_t* out_len);

void        pi_agent_clear_messages(pi_agent_t* a);
void        pi_agent_clear_steering_queue(pi_agent_t* a);
void        pi_agent_clear_follow_up_queue(pi_agent_t* a);

/* ============================================================ */
/*  Lifecycle hooks (D-9, D-10, D-11)                           */
/* ============================================================ */

/* Hook event types - 35 hooks across 7 namespaces. Numeric values are
 * STABLE. Phase numbers reflect the D-9 rollout schedule. */
typedef enum {
    /* Phase 0 (already implemented) */
    PI_HOOK_SESSION_START               = 100,
    PI_HOOK_AGENT_START                 = 101,
    PI_HOOK_AGENT_END                   = 102,

    /* Phase 1 (v0.2 - the governance milestone) */
    PI_HOOK_TOOL_CALL                   = 200, /* intercept */
    PI_HOOK_TOOL_RESULT                 = 201, /* intercept */
    PI_HOOK_TOOL_EXECUTION_START        = 202,
    PI_HOOK_TOOL_EXECUTION_UPDATE       = 203,
    PI_HOOK_TOOL_EXECUTION_END          = 204,
    PI_HOOK_TURN_START                  = 210,
    PI_HOOK_TURN_END                    = 211,
    PI_HOOK_MESSAGE_START               = 212,
    PI_HOOK_MESSAGE_UPDATE              = 213,
    PI_HOOK_MESSAGE_END                 = 214,

    /* Phase 2 (v0.5) */
    PI_HOOK_PROVIDER_BEFORE_REQUEST     = 300, /* intercept */
    PI_HOOK_PROVIDER_AFTER_RESPONSE     = 301,
    PI_HOOK_CONTEXT                     = 302, /* intercept */
    PI_HOOK_INPUT_USER_TEXT             = 310, /* intercept */
    PI_HOOK_INPUT_USER_BASH             = 311, /* intercept */

    /* Phase 3 (v1.0) */
    PI_HOOK_SESSION_BEFORE_SWITCH       = 400, /* intercept */
    PI_HOOK_SESSION_BEFORE_FORK         = 401, /* intercept */
    PI_HOOK_SESSION_BEFORE_COMPACT      = 402, /* intercept */
    PI_HOOK_SESSION_BEFORE_TREE         = 403, /* intercept */
    PI_HOOK_SESSION_COMPACT             = 410,
    PI_HOOK_SESSION_TREE                = 411,
    PI_HOOK_SESSION_SHUTDOWN            = 412,
    PI_HOOK_AGENT_MODEL_SELECT          = 420,
    PI_HOOK_AGENT_THINKING_LEVEL_SELECT = 421,
    PI_HOOK_RESOURCES_DISCOVER          = 430
} pi_hook_event_type_t;

/* Returns 1 if the given hook is an "intercept" type that can cancel or
 * modify the operation; 0 if it's a notify-only hook. */
int pi_hook_is_intercept(pi_hook_event_type_t type);

/* Output struct for intercept hooks. The framework reads these after the
 * callback returns. For notify hooks, this pointer is NULL and any writes
 * are ignored. */
typedef struct {
    int          cancel;             /* non-zero = short-circuit operation */
    const char*  reason;             /* nullable, valid until callback returns */
    size_t       reason_len;
    const char*  modified_args_json; /* nullable; replaces operation args */
    size_t       modified_args_len;
} pi_hook_result_t;

/* D-10: a single unified callback signature for ALL 35 hook types.
 * Type-specific data is read through getters keyed on hook_type. */
typedef int (*pi_hook_fn)(
    void*                       user_data,
    pi_hook_event_type_t        hook_type,
    const pi_hook_event_t*      event,        /* opaque, type-specific getters */
    pi_hook_result_t*           out_result    /* nullable for notify hooks */
);

/* Subscribe a host-side observer to a specific hook type. Extensions
 * register their own hooks via the protocol; this is for ad-hoc
 * SDK-consumer-side observers. */
pi_status_t pi_session_subscribe_hook(pi_session_t* session,
                                        pi_hook_event_type_t type,
                                        pi_hook_fn fn,
                                        void* user_data);

pi_status_t pi_session_unsubscribe_hook(pi_session_t* session,
                                          pi_hook_event_type_t type,
                                          pi_hook_fn fn,
                                          void* user_data);

/* ============================================================ */
/*  Hook event introspection (borrowed pointers, callback only) */
/* ============================================================ */

/* Tool hooks (PI_HOOK_TOOL_* / PI_HOOK_TOOL_EXECUTION_*) */
const char* pi_hook_event_tool_name(const pi_hook_event_t* e, size_t* out_len);
const char* pi_hook_event_tool_call_id(const pi_hook_event_t* e, size_t* out_len);
const char* pi_hook_event_args_json(const pi_hook_event_t* e, size_t* out_len);
const char* pi_hook_event_result_json(const pi_hook_event_t* e, size_t* out_len);
int         pi_hook_event_is_error(const pi_hook_event_t* e); /* -1 if N/A */

/* Message / turn hooks */
const char* pi_hook_event_message_json(const pi_hook_event_t* e, size_t* out_len);
const char* pi_hook_event_text_delta(const pi_hook_event_t* e, size_t* out_len);

/* Provider hooks */
const char* pi_hook_event_payload_json(const pi_hook_event_t* e, size_t* out_len);
const char* pi_hook_event_provider_id(const pi_hook_event_t* e, size_t* out_len);
const char* pi_hook_event_model_id(const pi_hook_event_t* e, size_t* out_len);

/* Input hooks */
const char* pi_hook_event_user_text(const pi_hook_event_t* e, size_t* out_len);

/* Session hooks */
const char* pi_hook_event_session_id(const pi_hook_event_t* e, size_t* out_len);

/* ============================================================ */
/*  Extensions                                                  */
/* ============================================================ */

pi_status_t pi_extension_load(pi_session_t* session,
                                const char* manifest_path, size_t path_len,
                                pi_principal_t* principal,
                                pi_extension_t** out);

void        pi_extension_unload(pi_extension_t* ext);

const char* pi_extension_id(const pi_extension_t* ext, size_t* out_len);
pi_runtime_kind_t pi_extension_runtime(const pi_extension_t* ext);

size_t      pi_extension_tool_count(const pi_extension_t* ext);
const char* pi_extension_tool_name_at(const pi_extension_t* ext, size_t i,
                                        size_t* out_len);

pi_status_t pi_extension_invoke_tool(pi_extension_t* ext,
                                       const char* tool_name, size_t tool_name_len,
                                       const char* args_json, size_t args_len,
                                       const volatile int* abort_flag,
                                       pi_tool_result_t** out_result);

/* ============================================================ */
/*  Convenience: top-level "run agent" one-shot                 */
/* ============================================================ */

pi_status_t pi_run_once(pi_session_t* session,
                          pi_workspace_t* ws,
                          pi_principal_t* principal,
                          const pi_agent_config_t* config,
                          const char* prompt_text, size_t prompt_len,
                          const char** out_response, size_t* out_len);

#ifdef __cplusplus
}
#endif

#endif /* PI_H */
