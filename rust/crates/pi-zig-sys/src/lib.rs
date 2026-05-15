use std::os::raw::c_uchar;

#[link(name = "pi_zig_kernel", kind = "static")]
unsafe extern "C" {
    pub fn pi_fuzzy_filter_batch(
        query_ptr: *const c_uchar,
        query_len: usize,
        items_json_ptr: *const c_uchar,
        items_json_len: usize,
        out_len: *mut usize,
    ) -> *mut c_uchar;

    pub fn pi_zig_free(ptr: *mut c_uchar, len: usize);
}
