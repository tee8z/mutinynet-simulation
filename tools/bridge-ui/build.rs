use minify_js::{minify, Session, TopLevelMode};
use sha2::{Digest, Sha256};
use std::{env, fs, path::Path};
use walkdir::WalkDir;

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").unwrap();
    let templates = Path::new(&manifest).join("src/dashboard");
    let output = Path::new(&manifest).join("static");

    if !templates.exists() {
        emit_asset_hashes("", "");
        return;
    }

    println!("cargo:rerun-if-changed={}", templates.display());
    for entry in WalkDir::new(&templates).into_iter().filter_map(Result::ok) {
        let ext = entry.path().extension().and_then(|e| e.to_str());
        if matches!(ext, Some("js") | Some("css")) {
            println!("cargo:rerun-if-changed={}", entry.path().display());
        }
    }

    let _ = fs::create_dir_all(&output);
    let js_hash = build_js(&templates, &output);
    let css_hash = build_css(&templates, &output);
    emit_asset_hashes(&js_hash, &css_hash);
}

fn build_js(templates: &Path, output: &Path) -> String {
    let mut files = WalkDir::new(templates)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "js"))
        .map(|entry| entry.path().to_path_buf())
        .collect::<Vec<_>>();
    files.sort();

    let mut combined = String::new();
    for file in files {
        if let Ok(content) = fs::read_to_string(&file) {
            combined.push_str(&content);
            combined.push('\n');
        }
    }

    if combined.trim().is_empty() {
        return String::new();
    }

    let minified = try_minify_js(&combined).unwrap_or(combined);
    let minified = minified.trim_end().to_string();
    let short = short_hash(minified.as_bytes());
    clean_old_hash_files(output, "app.", ".min.js", &short);
    let _ = fs::write(output.join(format!("app.{short}.min.js")), &minified);
    let _ = fs::write(output.join("app.min.js"), &minified);
    short
}

fn build_css(templates: &Path, output: &Path) -> String {
    let mut files = WalkDir::new(templates)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "css"))
        .map(|entry| entry.path().to_path_buf())
        .collect::<Vec<_>>();
    files.sort();

    let mut combined = String::new();
    for file in files {
        if let Ok(content) = fs::read_to_string(&file) {
            combined.push_str(&content);
            combined.push('\n');
        }
    }

    if combined.trim().is_empty() {
        return String::new();
    }

    let minified = minify_css(&combined).trim_end().to_string();
    let short = short_hash(minified.as_bytes());
    clean_old_hash_files(output, "styles.", ".min.css", &short);
    let _ = fs::write(output.join(format!("styles.{short}.min.css")), &minified);
    let _ = fs::write(output.join("styles.min.css"), &minified);
    short
}

fn try_minify_js(source: &str) -> Option<String> {
    use std::panic::{catch_unwind, AssertUnwindSafe};

    let session = Session::new();
    let mut out = Vec::new();
    catch_unwind(AssertUnwindSafe(|| {
        minify(&session, TopLevelMode::Global, source.as_bytes(), &mut out).ok()?;
        String::from_utf8(out).ok()
    }))
    .ok()?
}

fn minify_css(css: &str) -> String {
    let mut out = String::with_capacity(css.len());
    let mut in_comment = false;
    let mut chars = css.chars().peekable();

    while let Some(ch) = chars.next() {
        if in_comment {
            if ch == '*' && chars.peek() == Some(&'/') {
                chars.next();
                in_comment = false;
            }
            continue;
        }
        if ch == '/' && chars.peek() == Some(&'*') {
            chars.next();
            in_comment = true;
            continue;
        }
        if ch.is_whitespace() {
            if !out.ends_with(|prev: char| prev.is_whitespace() || "{:;,".contains(prev))
                && chars.peek().is_some_and(|next| !"{}:;,".contains(*next))
            {
                out.push(' ');
            }
            continue;
        }
        out.push(ch);
    }

    out
}

fn short_hash(bytes: &[u8]) -> String {
    let hash = hex::encode(Sha256::digest(bytes));
    hash[..8].to_string()
}

fn clean_old_hash_files(output: &Path, prefix: &str, suffix: &str, current_hash: &str) {
    if let Ok(entries) = fs::read_dir(output) {
        for entry in entries.filter_map(Result::ok) {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with(prefix)
                && name.ends_with(suffix)
                && name.len() > prefix.len() + suffix.len()
            {
                let hash_part = &name[prefix.len()..name.len() - suffix.len()];
                if hash_part.len() == 8
                    && hash_part.chars().all(|ch| ch.is_ascii_hexdigit())
                    && hash_part != current_hash
                {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
    }
}

fn emit_asset_hashes(js_hash: &str, css_hash: &str) {
    let out_dir = env::var("OUT_DIR").unwrap();
    let dest = Path::new(&out_dir).join("asset_hashes.rs");
    let js_file = if js_hash.is_empty() {
        "app.min.js".to_string()
    } else {
        format!("app.{js_hash}.min.js")
    };
    let css_file = if css_hash.is_empty() {
        "styles.min.css".to_string()
    } else {
        format!("styles.{css_hash}.min.css")
    };

    let content = format!(
        r#"pub const JS_HASHED: &str = "{js_file}";
pub const CSS_HASHED: &str = "{css_file}";
"#
    );
    let _ = fs::write(dest, content);
}
