use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt::{Display, Formatter};
use std::ptr::NonNull;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FuzzyItem {
    pub id: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct FuzzyMatch {
    pub id: String,
    pub score: u32,
}

#[derive(Debug)]
pub enum ZigError {
    KernelReturnedNull,
    Json(serde_json::Error),
}

impl Display for ZigError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ZigError::KernelReturnedNull => write!(f, "Zig kernel returned null"),
            ZigError::Json(error) => write!(f, "JSON error: {error}"),
        }
    }
}

impl Error for ZigError {}

impl From<serde_json::Error> for ZigError {
    fn from(error: serde_json::Error) -> Self {
        ZigError::Json(error)
    }
}

struct ZigBuffer {
    ptr: NonNull<u8>,
    len: usize,
}

impl ZigBuffer {
    fn as_slice(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr.as_ptr(), self.len) }
    }
}

impl Drop for ZigBuffer {
    fn drop(&mut self) {
        unsafe { pi_zig_sys::pi_zig_free(self.ptr.as_ptr(), self.len) };
    }
}

pub fn fuzzy_filter(query: &str, items: &[FuzzyItem]) -> Result<Vec<FuzzyMatch>, ZigError> {
    let items_json = serde_json::to_vec(items)?;
    let mut out_len = 0usize;
    let ptr = unsafe {
        pi_zig_sys::pi_fuzzy_filter_batch(
            query.as_ptr(),
            query.len(),
            items_json.as_ptr(),
            items_json.len(),
            &mut out_len,
        )
    };

    let ptr = NonNull::new(ptr).ok_or(ZigError::KernelReturnedNull)?;
    let buffer = ZigBuffer { ptr, len: out_len };
    let matches = serde_json::from_slice(buffer.as_slice())?;
    Ok(matches)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn items() -> Vec<FuzzyItem> {
        vec![
            FuzzyItem {
                id: "main".into(),
                text: "src/main.rs".into(),
            },
            FuzzyItem {
                id: "lib".into(),
                text: "src/lib.rs".into(),
            },
        ]
    }

    #[test]
    fn fuzzy_filter_returns_matching_item() {
        let matches = fuzzy_filter("mn", &items()).unwrap();
        assert_eq!(matches[0].id, "main");
    }

    #[test]
    fn fuzzy_filter_empty_query_returns_all_items() {
        let matches = fuzzy_filter("", &items()).unwrap();
        assert_eq!(matches.len(), 2);
    }

    #[test]
    fn fuzzy_filter_empty_items_returns_empty_matches() {
        let matches = fuzzy_filter("anything", &[]).unwrap();
        assert!(matches.is_empty());
    }
}
