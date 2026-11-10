use serde_json::Value;
use std::ffi::{CStr, CString, c_char};
unsafe extern "C" {
    fn monosplit_host_init();
    fn monosplit_host_snapshot() -> *mut c_char;
    fn monosplit_host_command(command: *const c_char);
    fn monosplit_host_free(pointer: *mut c_char);
}
// Called exclusively from GPUI's main thread, matching the Swift MainActor contract.
pub fn init() {
    unsafe { monosplit_host_init() }
}
pub fn send(value: &Value) {
    if let Ok(command) = CString::new(value.to_string()) {
        unsafe { monosplit_host_command(command.as_ptr()) }
    }
}
pub fn snapshot() -> anyhow::Result<Value> {
    let pointer = unsafe { monosplit_host_snapshot() };
    anyhow::ensure!(!pointer.is_null(), "音频核心尚未就绪");
    let text = unsafe { CStr::from_ptr(pointer) }.to_bytes();
    let result = serde_json::from_slice(text);
    unsafe { monosplit_host_free(pointer) };
    Ok(result?)
}
