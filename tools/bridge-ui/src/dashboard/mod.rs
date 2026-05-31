use axum::{
    extract::Path,
    http::{header, StatusCode},
    response::IntoResponse,
    routing::get,
    Router,
};
use rust_embed::Embed;

use crate::AppState;

pub mod asset_hashes;
pub mod layouts;
pub mod pages;

#[derive(Embed)]
#[folder = "static/"]
struct StaticAssets;

async fn static_handler(Path(path): Path<String>) -> impl IntoResponse {
    match StaticAssets::get(&path) {
        Some(file) => {
            let mime = mime_guess::from_path(&path).first_or_octet_stream();
            (
                [(header::CONTENT_TYPE, mime.as_ref().to_string())],
                file.data.into_owned(),
            )
                .into_response()
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

pub(crate) fn dashboard_routes() -> Router<AppState> {
    Router::new()
        .route("/", get(pages::home))
        .route("/static/{*path}", get(static_handler))
}
