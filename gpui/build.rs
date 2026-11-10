fn main() {
    let root = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    println!(
        "cargo:rustc-link-search=native={}",
        root.join("../build/gpui-native").display()
    );
    println!("cargo:rustc-link-lib=dylib=MonoSplitHost");
    println!("cargo:rustc-link-arg=-Wl,-rpath,@executable_path/../Frameworks");
    println!(
        "cargo:rustc-link-arg=-Wl,-rpath,{}",
        root.join("../build/gpui-native").display()
    );
    println!("cargo:rerun-if-changed=../build/gpui-native/libMonoSplitHost.dylib");
}
