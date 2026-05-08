const sdk = @import("pi-extension-sdk");

const input_schema_json =
    \\{"type":"object","required":["message"],"properties":{"message":{"type":"string"}}}
;
const output_schema_json =
    \\{"type":"object","required":["message"],"properties":{"message":{"type":"string"}}}
;

const metadata_json = sdk.staticMetadataJson(
    "template.echo",
    "Pi Zig Echo Template",
    "0.1.0",
    "Echoes a message field from the JSON input.",
);
const schema_json = sdk.staticSchemaJson(input_schema_json, output_schema_json);

var execute_output: [sdk.MAX_EXECUTE_OUTPUT_BYTES]u8 = undefined;
var execute_output_len: usize = 0;

export fn metadata() i32 {
    return sdk.ptr(metadata_json);
}

export fn metadata_len() i32 {
    return sdk.len(metadata_json);
}

export fn schema() i32 {
    return sdk.ptr(schema_json);
}

export fn schema_len() i32 {
    return sdk.len(schema_json);
}

export fn execute(input_ptr: [*]const u8, input_len: usize) i32 {
    const input = input_ptr[0..input_len];
    const output = sdk.executeMessageEcho(&execute_output, input);
    execute_output_len = output.len;
    return sdk.ptr(output);
}

export fn execute_len() i32 {
    return @intCast(execute_output_len);
}
