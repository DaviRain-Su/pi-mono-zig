const sdk = @import("pi-native-extension-sdk");

const input_schema_json =
    \\{"type":"object","required":["message"],"properties":{"message":{"type":"string"}}}
;
const output_schema_json =
    \\{"type":"object","required":["message"],"properties":{"message":{"type":"string"}}}
;

const metadata_json = sdk.staticMetadataJson(
    "com.pi.native.template.echo",
    "Pi Native Zig Echo Template",
    "0.1.0",
    "Echoes a message field through the native dynamic runtime boundary.",
    "native.echo",
    "Echoes a message field from the JSON input.",
    input_schema_json,
    output_schema_json,
);

var execute_output: [sdk.MAX_EXECUTE_OUTPUT_BYTES]u8 = undefined;
var execute_output_len: usize = 0;

export fn pi_native_extension_abi_version() u32 {
    return sdk.ABI_VERSION;
}

export fn pi_native_extension_abi_name_ptr() [*]const u8 {
    return sdk.ptr(sdk.ABI_NAME);
}

export fn pi_native_extension_abi_name_len() usize {
    return sdk.len(sdk.ABI_NAME);
}

export fn pi_native_extension_metadata_ptr() [*]const u8 {
    return sdk.ptr(metadata_json);
}

export fn pi_native_extension_metadata_len() usize {
    return sdk.len(metadata_json);
}

export fn pi_native_extension_validate() i32 {
    return 0;
}

export fn pi_native_extension_execute(input_ptr: [*]const u8, input_len: usize) [*]const u8 {
    const input = input_ptr[0..input_len];
    const output = sdk.executeMessageEcho(&execute_output, input);
    execute_output_len = output.len;
    return sdk.ptr(output);
}

export fn pi_native_extension_execute_len() usize {
    return execute_output_len;
}
